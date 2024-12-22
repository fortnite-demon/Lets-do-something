#!/usr/bin/env bash

set -ox pipefail

BACKUP_DIR=""
SOURCE_DIR=""
DEPENDENCIES=("tar" "printf" "wc" "date" "gzip" "gpg" "s3cmd" "tee" "bc" "df" "nl" "sha256sum")
LOG_FILE_PATH="/var/log/backup.log"
BACKUP_NAME="$(date +%Y-%d-%m_%H-%M-%S).tar.gz"
GPG_KEY=""
UNENCRYPT_BACKUP_DEL="FALSE"
BUCKET=""
S3_SEND="FALSE"
S3CMD_CONF=""
SEND_ENCRYPT_BACKUP="FALSE"
SPACE_THRESHOLD=100

usage() {
    printf "
Usage:
    backup.sh [ ...OPTIONS... [ ARG ] ]

Details:

\033[31m    REQUIRED:\033[37m These options are required for the script to work.
    --------
    optional: You can specify these options or not, as you wish.
    --------
\033[30m    other:\033[37m    These are all other options, the logic of the script is not based on them, 
              for example: -h \"help\"

                          --- OPTIONS ---

                      Default backup section:

    -----------------------------------------------------------------+
    [ -d <source-dir> (str) ]:     Path to source dir.               | \033[31mREQUIRED\033[37m
    -----------------------------------------------------------------|
    [ -b <dir-for-backup> (str) ]: Path to dir for backups.          | \033[31mREQUIRED\033[37m
    -----------------------------------------------------------------|
    [ -l <log-file-path> (str) ]:  Path to log file.                 | optional
                                                                     |
                                   Default: /var/log/backup.log      |
    -----------------------------------------------------------------|
    [ -n <backup-name> (str) ]:    Name for backup.                  | optional    
                                                                     |
                                   Default: YYYY-dd-mm_HH-MM-SS      |  
    -----------------------------------------------------------------+
    [ -t <percent> (1-100) ]:      You can set a threshold value on  | optional
                                   the disk at which new backups     |
                                   will no longer be created.        |
                                   By default, copies will not be    |
                                   created if there is no free space |
                                   on the disk at all.               |
    -----------------------------------------------------------------+

                       Backup with encrypted:

    -----------------------------------------------------------------+
    [ -g <gpg-key> (str) ]:        GPG Key for encrypt backup.       | optional                                                        
                                   NOTE: specify the key that has    |
                                   already been added to the         |
                                   gpg ring, this script will not    |
                                   add it automatically.             |
    -----------------------------------------------------------------|
    [ -d (TRUE|FALSE) ]:           Delete the unencrypted backup,    | optional
                                   used with: [ -g <gpg-key> ].      |
                                   NOTE: Only the backup that was    |
                                   created by the current script     |
                                   instance is deleted.              |
                                                                     |
                                   NEEDS: [ -g ]                     |
    -----------------------------------------------------------------+

                       Backup with send to S3: 

    -----------------------------------------------------------------+
    [ -f <s3cmd-cnf-path> (str) ]: Path to configuration file for    | optional
                                   s3cmd.                            |
                                   Default: /home/<UID>/.s3cmd       |
    -----------------------------------------------------------------|
    [ -S <s3-send> (TRUE|FALSE) ]: Whether the backup will be sent   | optional
                                   to the object storage.            | 
                                   Note: this script does not        |
                                   automatically configure s3cmd and |
                                   does not create a bucket.         |
                                   He just sends him there.          |
    -----------------------------------------------------------------|
    [ -B <bucket-name> (str) ]:    The name of the bucket to which   | optional 
                                   the backup will be sent.          | 
                                                                     |
                                   NEEDS: [ -o ]                     |
    -----------------------------------------------------------------|
    [ -c <encrypt> (TRUE|FALSE) ]: If you did not use the [ -d ]     | optional
                                   option to delete the unencrypted  |
                                   backup version, then you can      |
                                   choose which version to send      |
                                   to the S3 Bucket.                 |
                                                                     |
                                   Default: FALSE                    |
                                                                     | 
                                   NEEDS: [ -g ] for send encrypt    | 
                                   backup                            |
    -----------------------------------------------------------------+
                                                                     
                            Other options:                           

    -----------------------------------------------------------------+
    [ -h ]:                        Print this message.               | \033[30mother\033[37m
    -----------------------------------------------------------------+\n\n" >&2
    exit 1
}

log() {
    local severity="${1}"
    local message="${2}"
    echo -e "[$(date +%Y-%d-%m)|$(date +%T.%2N)] :${severity}: ${message}" &>> "${LOG_FILE_PATH}"
}

log_file_validate() {

    local temp_output_file="$(mktemp --suffix=backupshLOG$(date +%Y-%m-%d_%T))"

    local logfile_dir_name=$(dirname $LOG_FILE_PATH)

    if [[ -f ${LOG_FILE_PATH} ]]; then
        if [[ ! -w ${LOG_FILE_PATH} ]]; then
            echo -e "letsbackup.sh: FAILED, <${LOG_FILE_PATH}> not access write!\nLOG:${temp_output_file}" | tee -a ${temp_output_file} >&2
            exit 1
        fi
        return 0
    fi
    if [[ -d ${LOG_FILE_PATH} ]]; then
        echo -e "letsbakcup.sh: FAILED, <${LOG_FILE_PATH}> is directory!\nLOG:${temp_output_file}" | tee -a ${temp_output_file} >&2
        exit 1
    elif [[ ! -w ${logfile_dir_name} ]]; then
        echo -e "letsbakcup.sh: FAILED, dir <${logfile_dir_name}> for logfile not access to write!\nLOG:${temp_output_file}" | tee -a ${temp_output_file} >&2
        exit 1
    fi

    touch "${LOG_FILE_PATH}"
}

check_dir_permissions() {

    local mode="${1}"
    local dir_path="${2}"

    if [[ -d ${dir_path} ]]; then
        if [[ ${mode} = "w" ]]; then
            if [[ ! -w ${dir_path} ]]; then
                log "CRITICAL" "<${dir_path}> DIR NOT ACCES TO WRITE! EXIT"
                echo "letsbackup.sh: FAILED, <${dir_path}> dir not access to write! EXIT" >&2
                exit 1
            fi
        elif [[ ${mode} = "r" ]]; then
            if [[ ! -r ${dir_path} ]]; then
                log "CRITICAL" "<${dir_path}> DIR NOT ACCES TO READ! EXIT"
                echo "letsbackup.sh: FAILED, <${dir_path}> dir not access to read! EXIT" >&2
                exit 1
            fi
        fi
    else
        log "CRITICAL" "<${dir_path}> DIR NOT FOUND! EXIT"
        echo "letsbackup.sh: FAILED, <${dir_path}> dir not found!" >&2
        exit 1
    fi
}

check_dependencies() {

    local dependencies="${@}"

    for dependence in ${dependencies[@]}; do
        if ! command -v ${dependence} &> /dev/null; then
            log "CRITICAL" "DEPENDENCE <${dependence}> REQUIRED! EXIT"
            echo "letsbackup.sh: FAILED, dependence <${dependence}> REQUIRED!" >&2
            exit 1
        fi
    done
}

check_step_for_falure() {
    local severity="${1}"
    local message="${2}"
    if [[ $? -ne 0 ]]; then
        if [[ -n $3 ]]; then
            local output="$(cat $3)"
            log "${severity}" "${message}\n${output}" 
            { \
                echo "letsbackup.sh: ${severity}, ${message}";
                echo "${output}";
            } >&2
        else
            log "${severity}" "${message}"
            echo "backup.sh: FAILED, ${message}" >&2
        fi
        rm -rf ${2} &> /dev/null
    fi
}

backup() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"

    log "INFO" "Start backup process..."
    echo "letsbackup.sh: INFO, Start backup process..."

    test -f "${BACKUP_DIR}/${BACKUP_NAME}" && { \ 
        log "CRITICAL" "BACKUP WITH NAME: ${BACKUP_NAME} already exists in ${BACKUP_DIR} EXIT";
        echo "letsbackup.sh: FAILED, BACKUP WITH NAME: ${BACKUP_NAME} already exists in ${BACKUP_DIR}";
        exit 1;
    }

    tar -czvf ${BACKUP_DIR}/${BACKUP_NAME} -C ${SOURCE_DIR} . 2> ${temp_output_file} > /dev/null
    check_step_for_falure "CRITICAL" "BACKUP PROCESS FAILURE! EXIT MORE:\n" "${temp_output_file}"

    backup_hash="$(sha256sum ${BACKUP_DIR}/${BACKUP_NAME} | awk '{print $1}')"

    log "INFO" "Backup process SUCCESS! Backup Info: name=\"${BACKUP_DIR}/${BACKUP_NAME}\", size=\"$(ls -tlh | nl -nln | awk '/^2 /{print $6; exit}')\" sha256=\"${backup_hash}\""
    echo "letsbackup.sh: INFO, Backup process SUCCESS! sha256=\"${backup_hash}\""

    rm -rf "${temp_output_file}" &> /dev/null

}

disk_space_threshold_check() {

    local current_disk_avail="$(df -x tmpfs | nl -nln | awk '/^[2-9]+ /{totalAvail+=$5} END {print totalAvail}')"
    local current_disk_size="$(df -x tmpfs | nl -nln | awk '/^[2-9]+ /{totalSize+=$3} END {print totalSize}')"
    local disk_space_usage_percent="$(echo "(1 - ${current_disk_avail} / ${current_disk_size}) * 100" | bc -l | awk -F. '{print $1}')"

    if [[ ${disk_space_usage_percent} -ge ${SPACE_THRESHOLD} ]]; then
        log "CRITICAL" "NEW BACKUP WILL NOT BE CREATED, THE THRESHOLD: ${SPACE_THRESHOLD}% HAS BEEN REACHED! AVAIL: $(expr $current_disk_avail / 1024 / 1024)GB EXIT"
        echo "letsbackup.sh: FAILED, NEW BACKUP WILL NOT BE CREATED, THE THRESHOLD: ${SPACE_THRESHOLD}% HAS BEEN REACHED! AVAIL: $(expr $current_disk_avail / 1024 / 1024)GB"
        exit 1
    fi
}

threshold_value_validate() {
    local min="1"
    local max="100"

    echo "${SPACE_THRESHOLD}" | grep -P "^\d+$" &>/dev/null || { \
        log "CRITICAL" "THIS SPACE_THRESHOLD VALUE: ${SPACE_THRESHOLD} NOT SUPPORTED! EXIT";
        echo "letsbackup.sh: FAILED, THIS SPACE_THRESHOLD VALUE: ${SPACE_THRESHOLD} NOT SUPPORTED!";
        exit 1;
    }

    if [[ ! ${SPACE_THRESHOLD} -ge ${min} || ! ${SPACE_THRESHOLD} -le ${max}  ]]; then
        log "CRITICAL" "THRESHOLD VALUE NOT IN RANGE! THRESHOLD: ${SPACE_THRESHOLD} RANGE: ${min}-${max} EXIT"
        echo "letsbackup.sh: FAILED, THRESHOLD VALUE NOT IN RANGE! THRESHOLD: ${SPACE_THRESHOLD} RANGE: ${min}-${max}"
        exit 1
    fi
}

backup_encrypt() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"

    log "INFO" "Start encrypt process... Backup Name: ${BACKUP_NAME}"
    echo "letsbackup.sh: INFO, Start encrypt process..."
    gpg --armor --encrypt --recipient "${GPG_KEY}" "${BACKUP_DIR}/${BACKUP_NAME}" > /dev/null 2> "${temp_output_file}"
    check_step_for_falure "CRITICAL" "ENCRYPT PROCESS WITH: GPG FAILED! EXIT MORE:\n" "${temp_output_file}"

    log "INFO" "Encrypt process SUCCESS! Info: backup=\"${BACKUP_DIR}/${BACKUP_NAME}\", encryptBackupName=\"${BACKUP_NAME}.asc\""
    echo "letsbackup.sh: INFO, Encrypt process SUCCESS! Info: backup=\"${BACKUP_DIR}/${BACKUP_NAME}\", encryptBackupName=\"${BACKUP_NAME}.asc\""

    rm -rf "${temp_output_file}" &> /dev/null
}

s3_send() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"
    local send_backup_name="${1}"

    log "INFO" "Start send to s3 process... Bucket Name: ${BUCKET}"
    echo "letsbackup.sh: INFO, Start send to s3 process..."
    s3cmd put "${BACKUP_DIR}/${1}" s3://"${BUCKET}"/"${1}" 2> "${temp_output_file}" > /dev/null
    check_step_for_falure "CRITICAL" "SEND BACKUP TO S3 FAILED! EXIT MORE:\n" "${temp_output_file}"

    log "INFO" "Send backup process SUCCESS! Info: bucket=${BUCKET}, backupNameInBucket=${1}"
    echo "letsbackup.sh: INFO, Send backup process SUCCESS!"

    rm -rf "${temp_output_file}" &> /dev/null

}

s3cmd_conf_validate() {

    if [[ -f ${S3CMD_CONF} ]]; then
        if [[ ! -r ${S3CMD_CONF} ]]; then

            log "CRITICAL" "NOT PERMISSION TO READ CONF FILE: ${S3CMD_CONF} s3cmd! EXIT"
            echo "letsbackup.sh: FAILED, NOT PERMISSION TO READ CONF FILE: ${S3CMD_CONF} s3cmd!" >&2
            exit 1
        fi
        s3cmd --config="${S3CMD_CONF}" &> /dev/null
        return 0
    fi
    log "CRITICAL" "NOT FOUND CONF FILE ${S3CMD_CONF} s3cmd! EXIT"
    echo "letsbackup.sh: FAILED, NOT FOUND s3cmd CONFIG!" >&2
    exit 1
}

while getopts ":s:b:n:hl:g:dSf:B:ct:" opt; do
    case $opt in
        s) SOURCE_DIR="${OPTARG%/}"
        ;;
        b) BACKUP_DIR="${OPTARG%/}"
        ;;
        n) BACKUP_NAME="${OPTARG}"
        ;;
        l) LOG_FILE_PATH="${OPTARG}"
        ;; 
        g) GPG_KEY="${OPTARG}"
        ;;
        d) UNENCRYPT_BACKUP_DEL="TRUE"
        ;;
        S) S3_SEND="TRUE"
        ;;
        f) S3CMD_CONF="${OPTARG}"
        ;;
        B) BUCKET="${OPTARG}"
        ;;
        c) SEND_ENCRYPT_BACKUP="TRUE"
        ;;
        t) SPACE_THRESHOLD="${OPTARG}"
        ;;
        h)
           usage
        ;;
       \?)
           echo "letsbackup.sh: Failed, unknown option [ -$OPTARG ]" >&2
           echo "Use: [ -h ] for more information" >&2
           exit 1
        ;;
        :)
           echo "letsbackup.sh: Failed, option [ -$OPTARG ] needs at argument" >&2
           echo "Use: [ -h ] for more information" >&2
           exit 1
        ;;
    esac
done

check_dependencies "${DEPENDENCIES[@]}"

log_file_validate

check_dir_permissions "r" "${SOURCE_DIR}"

check_dir_permissions "w" "${BACKUP_DIR}"

threshold_value_validate

disk_space_threshold_check

backup

if [[ -n ${GPG_KEY} ]]; then
    backup_encrypt
    if [[ ${UNENCRYPT_BACKUP_DEL} = "TRUE" ]]; then

        log "INFO" "Start unencrypted backup remove process..."
        echo "letsbackup.sh: INFO, Start unencrypted backup remove process..."

        rm -rf "${BACKUP_DIR}/${BACKUP_NAME}" &> /dev/null
        check_step_for_falure "WARNING" "Backup: <${BACKUP_DIR}/${BACKUP_NAME}> remove process failed!"

        log "INFO" "Remove process success! Removed: <${BACKUP_DIR/${BACKUP_NAME}}>"
        echo "letsbackup.sh: INFO, Unencrypted backup remove SUCCESS!"
    fi
fi

if [[ ${S3_SEND} = "TRUE" ]]; then
    if [[ -n ${S3CMD_CONF} ]]; then
        s3cmd_conf_validate
    fi
    if [[ ${SEND_ENCRYPT_BACKUP} = "TRUE" ]]; then
        if [[ -z ${GPG_KEY} ]]; then
            log "CRITICAL" "ENCRYPT BACKUP NOT SEND! NEEDS GPG PROCESS! EXIT"
            echo "letsbackup.sh: FAILED, ENCRYPT BACKUP NOT SEND! NEEDS GPG PROCESS!"
            exit 1
        fi
        encrypt_backupname_to_send="${BACKUP_NAME}.asc"
        s3_send "${encrypt_backupname_to_send}"
    else 
        s3_send "${BACKUP_NAME}"
    fi
fi

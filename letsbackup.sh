#!/usr/bin/env bash

set -o pipefail

BACKUP_DIR=""
SOURCE_DIR=""
DEPENDENCIES=("tar" "printf" "wc" "date" "gzip" "gpg" "s3cmd" "tee")
LOG_FILE_PATH="/var/log/backup.log"
BACKUP_NAME="$(date +%Y-%d-%m_%H-%M-%S).tar.gz"
GPG_KEY=""
UNENCRYPT_BACKUP_DEL="FALSE"
BUCKET=""
S3_SEND="FALSE"
S3CMD_CONF=""
SEND_ENCRYPT_BACKUP="FALSE"
SPACE_THRESHOLD=""

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
    echo "[$(date +%Y-%d-%m)|$(date +%T.%2N)] :${severity}: ${message}" &>> "${LOG_FILE_PATH}"
}

log_file_validate() {

    local temp_output_file="$(mktemp --suffix=backupshLOG$(date +%Y-%m-%d_%T))"

    local logfile_dir_name=$(dirname $LOG_FILE_PATH)

    if [[ -f ${LOG_FILE_PATH} ]]; then
        if [[ ! -w ${LOG_FILE_PATH} ]]; then
            printf "letsbackup.sh: FAILED, <${LOG_FILE_PATH}> not access write!\nLOG:${temp_output_file}\n" | tee -a ${temp_output_file} >&2
            exit 1
        fi
        return 0
    fi
    if [[ -d ${LOG_FILE_PATH} ]]; then
        printf "letsbakcup.sh: FAILED, <${LOG_FILE_PATH}> is directory!\nLOG:${temp_output_file}\n" | tee -a ${temp_output_file} >&2
        exit 1
    elif [[ ! -w ${logfile_dir_name} ]]; then
        printf "letsbakcup.sh: FAILED, dir <${logfile_dir_name}> for logfile not access to write!\nLOG:${temp_output_file}\n" | tee -a ${temp_output_file} >&2
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
                printf "letsbackup.sh: FAILED, <${dir_path}> dir not access to write! EXIT\n" >&2
                exit 1
            fi
        elif [[ ${mode} = "r" ]]; then
            if [[ ! -r ${dir_path} ]]; then
                log "CRITICAL" "<${dir_path}> DIR NOT ACCES TO READ! EXIT"
                printf "letsbackup.sh: FAILED, <${dir_path}> dir not access to read! EXIT\n" >&2
                exit 1
            fi
        fi
    else
        log "CRITICAL" "<${dir_path}> DIR NOT FOUND! EXIT"
        printf "letsbackup.sh: FAILED, <${dir_path}> dir not found!\n" >&2
        exit 1
    fi
}

check_dependencies() {

    local dependencies="${@}"

    for dependence in ${dependencies[@]}; do
        if ! command -v ${dependence} &> /dev/null; then
            log "CRITICAL" "DEPENDENCE <${dependence}> REQUIRED! EXIT"
            echo "letsbackup.sh: FAILED, dependence <${dependence}> REQUIRED!\n" >&2
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
            printf "backup.sh: ${severity}, ${message}\n${output}" >&2
        else
            log "${severity}" "${message}"
            printf "backup.sh: FAILED, ${message}\n" >&2
        fi
        rm -rf ${2} &> /dev/null
    fi
}

backup() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"

    log "INFO" "Start backup process..."
    printf "letsbackup.sh: INFO, Start backup process...\n"
    tar -czvf ${BACKUP_DIR}/${BACKUP_NAME} -C ${SOURCE_DIR} . 2> ${temp_output_file} > /dev/null
    check_step_for_falure "CRITICAL" "BACKUP PROCESS FAILURE! EXIT MORE:\n" "${temp_output_file}"

    log "INFO" "Backup process SUCCESS! Backup Info: name=\"${BACKUP_DIR}/${BACKUP_NAME}\", size=\"$(ls -tlh | nl -nln | awk '/^2 /{print $6; exit}')\""
    printf "letsbackup.sh: INFO, Backup process SUCCESS!\n"

    rm -rf "${temp_output_file}" &> /dev/null

}

disk_space_check() {

}

backup_encrypt() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"

    log "INFO" "Start encrypt process... Backup Name: ${BACKUP_NAME}"
    printf "letsbackup.sh: INFO, Start encrypt process...\n"
    gpg --armor --encrypt --recipient "${GPG_KEY}" "${BACKUP_DIR}/${BACKUP_NAME}" > /dev/null 2> "${temp_output_file}"
    check_step_for_falure "CRITICAL" "ENCRYPT PROCESS WITH: GPG FAILED! EXIT MORE:\n" "${temp_output_file}"

    log "INFO" "Encrypt process SUCCESS! Info: backup=\"${BACKUP_DIR}/${BACKUP_NAME}\", encryptBackupName=\"${BACKUP_NAME}.asc\""
    printf "letsbackup.sh: INFO, Encrypt process SUCCESS! Info: backup=\"${BACKUP_DIR}/${BACKUP_NAME}\", encryptBackupName=\"${BACKUP_NAME}.asc\"\n"

    rm -rf "${temp_output_file}" &> /dev/null
}

s3_send() {
    trap 'rm -rf /tmp/*backupshOUTPUT' SIGINT SIGTERM SIGHUP

    local temp_output_file="$(mktemp --suffix=backupshOUTPUT$(date +%Y-%m-%d_%T))"
    local send_backup_name="${1}"

    log "INFO" "Start send to s3 process... Bucket Name: ${BUCKET}"
    printf "letsbackup.sh: INFO, Start send to s3 process...\n"
    s3cmd put "${BACKUP_DIR}/${1}" s3://"${BUCKET}"/"${1}" 2> "${temp_output_file}" > /dev/null
    check_step_for_falure "CRITICAL" "SEND BACKUP TO S3 FAILED! EXIT MORE:\n" "${temp_output_file}"

    log "INFO" "Send backup process SUCCESS! Info: bucket=${BUCKET}, backupNameInBucket=${1}"
    printf "letsbackup.sh: INFO, Send backup process SUCCESS!\n"

    rm -rf "${temp_output_file}" &> /dev/null

}

s3cmd_conf_validate() {

    if [[ -f ${S3CMD_CONF} ]]; then
        if [[ ! -r ${S3CMD_CONF} ]]; then

            log "CRITICAL" "NOT PERMISSION TO READ CONF FILE: ${S3CMD_CONF} s3cmd! EXIT"
            printf "letsbackup.sh: FAILED, NOT PERMISSION TO READ CONF FILE: ${S3CMD_CONF} s3cmd!\n" >&2
            exit 1
        fi
        s3cmd --config="${S3CMD_CONF}" &> /dev/null
        return 0
    fi
    log "CRITICAL" "NOT FOUND CONF FILE ${S3CMD_CONF} s3cmd! EXIT"
    printf "letsbackup.sh: FAILED, NOT FOUND s3cmd CONFIG!\n" >&2
    exit 1
}

while getopts ":s:b:n:hl:g:dSf:B:c" opt; do
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
           printf "letsbackup.sh: Failed, unknown option [ -$OPTARG ]\n" >&2
           printf "Use: [ -h ] for more information\n" >&2
           exit 1
        ;;
        :)
           printf "letsbackup.sh: Failed, option [ -$OPTARG ] needs at argument\n" >&2
           printf "Use: [ -h ] for more information\n" >&2
           exit 1
        ;;
    esac
done

check_dependencies "${DEPENDENCIES[@]}"

log_file_validate

check_dir_permissions "r" "${SOURCE_DIR}"

check_dir_permissions "w" "${BACKUP_DIR}"

backup

if [[ -n ${GPG_KEY} ]]; then
    backup_encrypt
    if [[ ${UNENCRYPT_BACKUP_DEL} = "TRUE" ]]; then

        log "INFO" "Start unencrypted backup remove process..."
        printf "letsbackup.sh: INFO, Start unencrypted backup remove process...\n"

        rm -rf "${BACKUP_DIR}/${BACKUP_NAME}" &> /dev/null
        check_step_for_falure "WARNING" "Backup: <${BACKUP_DIR}/${BACKUP_NAME}> remove process failed!"

        log "INFO" "Remove process success! Removed: <${BACKUP_DIR/${BACKUP_NAME}}>"
        printf "letsbackup.sh: INFO, Unencrypted backup remove SUCCESS!\n"
    fi
fi

if [[ ${S3_SEND} = "TRUE" ]]; then
    if [[ -n ${S3CMD_CONF} ]]; then
        s3cmd_conf_validate
    fi
    if [[ ${SEND_ENCRYPT_BACKUP} = "TRUE" ]]; then
        if [[ -z ${GPG_KEY} ]]; then
            log "CRITICAL" "ENCRYPT BACKUP NOT SEND! NEEDS GPG PROCESS! EXIT"
            printf "letsbackup.sh: FAILED, ENCRYPT BACKUP NOT SEND! NEEDS GPG PROCESS!"
            exit 1
        fi
        encrypt_backupname_to_send="${BACKUP_NAME}.asc"
        s3_send "${encrypt_backupname_to_send}"
    else 
        s3_send "${BACKUP_NAME}"
    fi
fi

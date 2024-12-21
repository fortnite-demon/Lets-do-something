# Let's backup - What is it?

This script automates the process of creating, encrypting, and uploading backups to an S3 bucket. It ensures data safety and accessibility with detailed logging and error handling.

## Features

- **Backup Creation**: Compresses and archives specified directories.
- **Encryption**: Encrypts backups using GPG for secure storage.
- **S3 Upload**: Uploads backups to an AWS S3 bucket.
- **Logging**: Provides detailed logs for process tracking and error diagnosis.

## Requirements

Ensure the following dependencies are installed on your system:

- `tar`
- `printf`
- `wc`
- `date`
- `gzip`
- `gpg`
- `s3cmd`

## Usage

To run the backup script, use the following options:

### Default backup section:

| Option | Description | Status | Needs Option |
|------------------------------|----------------------------------|-------|------|
| -d <source-dir> (str):    | Path to source dir.              | required | |
| -b <dir-for-backup> (str):| Path to dir for backups.         | required | |
| -l <log-file-path> (str): | Path to log file. Default: /var/log/backup.log | optional | |
| -n <backup-name> (str):   | Name for backup. Default: YYYY-dd-mm_HH-MM-SS | optional | |

### Backup with encrypted GPG

| Option | Description | Status | Needs Option |
|--------|------------|---------|--------------|
| -g <gpg-key> (str): | GPG Key for encrypt backup. NOTE: specify the key that has already been added to the gpg ring, this script will not add it automatically. | optional | |
| -d (TRUE\|FALSE):    | Delete the unencrypted backup, used with: [ -g <gpg-key> ]. NOTE: Only the backup that was created by the current script instance is deleted. | optional | -g |

### Backup with send to S3:

| Option | Description | Status | Needs Option |
|--------|-------------|--------|--------------| 
| -f <s3cmd-cnf-path> (str): | Path to configuration file for s3cmd Default: /home/<UID>/.s3cmd. | optional | -o |
| -o <s3-send> (TRUE\|FALSE): | Whether the backup will be sent to the object storage. to the object storage. Note: this script does not automatically configure s3cmd and does not create a bucket. He just sends him there. | optional | |
| -t <bucket-name> (str): | The name of the bucket to which the backup will be sent. | optinal | -o |
| -c <encrypt> (TRUE\|FALSE): | If you did not use the [ -d ] option to delete the unencrypted backup version, then you can choose which version to send to the s3 Bucket. Default: FALSE | optional | -o -g |

## Examples

- Creating a simple backup with a log entry in */var/log/letsbackup.log*:
  ```bash
  ./letsbackup.sh -s /path/to/sourceDir -b /path/to/backupDir
  ```
  Result:
  ```bash
  /path/to/backupDir/2024-21-12_20-35-37.tar.gz
  ```

- Create an encrypted backup, delete its unencrypted version, and create a custom log file *~/mylog.log*:
  ```bash
  ./letsbackup.sh -s ./src -b ./dst -g IMAGINETHATTHISISAGPGKEY -d
  ```
  Result:
  ```bash
  /path/to/backupDir/2024-21-12_20-50-44.tar.gz.asc
  ```
  *The -d option allows you to delete the unencrypted archim and leave only its encrypted version.*
- Creating a backup and sending it to the object storage:
  ```bash
  ./letsbackup.sh -s ./src -d ./dst -o -t mybucket
  ```
  Result: we will get a backup in the object storage.
- Log file output example:
  ```bash
  [2024-21-12|20:58:16.43] :INFO: Start backup process...
  [2024-21-12|20:58:16.45] :INFO: Backup process SUCCESS! Backup Info: name="backup/2024-21-12_20-58-16.tar.gz", size="4,0K"
  [2024-21-12|20:58:16.46] :INFO: Start encrypt process... Backup Name: 2024-21-12_20-58-16.tar.gz
  [2024-21-12|20:58:16.47] :INFO: Encrypt process SUCCESS! Info: backup="backup/2024-21-12_20-58-16.tar.gz", encryptBackupName="2024-21-12_20-58-16.tar.gz.asc"
  ```

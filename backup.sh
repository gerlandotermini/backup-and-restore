#!/bin/bash
WPCLI="/usr/local/bin/wp"

# Make sure all the parameters were specified
if [[ -z "$1" || -z "$2" ]]; then
    echo -e "Error: Please provide the path to the document root and the path to the backup folder:\nbackup.sh /var/www/html/something /var/www/backup-folder"
    exit 1
fi

# Does the folder exist?
if [ ! -d $1 ]; then
    echo "Error: Folder $1 does not exist. Aborting."
    exit 1
fi

WPDIR="${1%/}/wp/"

# Make sure the target backup folder exists
if [ ! -d ${2%/} ]; then
    mkdir ${2%/}
fi

BACKUPDIR="${2%/}/`date +%Y%m%d`"
# Create a temporary folder for all the files in this snapshot
if [ ! -d $BACKUPDIR ]; then
    mkdir $BACKUPDIR
fi

# Verify WP checksum
$WPCLI --path=$WPDIR core verify-checksums
 
# Backup the database
$WPCLI --path=$WPDIR db export "$BACKUPDIR/`date +%Y%m%d`.sql" --add-drop-table

# Save a snapshot of wp/plugins/themes versions associated to this DB backup
$WPCLI --path=$WPDIR core version > "$BACKUPDIR/`date +%Y%m%d`.core.txt"
$WPCLI --path=$WPDIR option get siteurl > "$BACKUPDIR/`date +%Y%m%d`.siteurl.txt"
$WPCLI --path=$WPDIR theme list --fields=name,version --format=csv > "$BACKUPDIR/`date +%Y%m%d`.themes.csv"
$WPCLI --path=$WPDIR plugin list --status=active,active-network,inactive --fields=name,version --format=csv > "$BACKUPDIR/`date +%Y%m%d`.plugins.csv"

# Remove CSV headers
sed -i "$BACKUPDIR/`date +%Y%m%d`.themes.csv" -e 1d
sed -i "$BACKUPDIR/`date +%Y%m%d`.plugins.csv" -e 1d

# Now package everything
cd $BACKUPDIR
/usr/bin/tar -czf "${2%/}/`date +%Y%m%d`.tar.gz" *

if [ $? -eq 0 ]; then
    echo "Success: Compressed backup as ${2%/}/`date +%Y%m%d`.tar.gz"
    rm -rf $BACKUPDIR
else
    echo 'Error: There was a problem compressing the snapshot.'
fi

# Delete files older than six months
cd ${2%/}
find . -mtime +180 -type f -delete

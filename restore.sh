#!/bin/bash
WPCLI="/usr/local/bin/wp"
GITPATH="git@gitlab.com:gccomms"

# Make sure we have all the parameters
if [[ -z "$1" || -z "$2" ]]; then
    echo -e "Please specify the path to the WordPress document root and the path to the backup file you'd like to restore:\nrestore.sh /var/www/html/ /var/www/backups/backupfile.tar.gz"
    exit 1
fi

# Does the document root exist?
if [ ! -d $1 ]; then
    echo "Error: Document root $1 not found. Aborting."
    exit 1
fi

# Does the backup file exist?
if [ ! -f $2 ]; then
    echo "Error: Backup file $2 not found. Aborting."
    exit 1
fi

WPDIR=${1%/}/wp
BACKUPFILEPATH=${2%/}
BACKUPFOLDER=`dirname $BACKUPFILEPATH`
BACKUPFILE=`basename "${BACKUPFILEPATH%%.*}"`

# Unpack the tar file
/usr/bin/tar xfz $BACKUPFILEPATH -C /tmp

# Does the backup file contain all the information we need?
if [ ! -f "/tmp/$BACKUPFILE.siteurl.txt" ]; then
    echo "Incomplete backup file: missing siteurl.txt. Aborting."
    exit
fi

BACKUPSITEURL=$(</tmp/$BACKUPFILE.siteurl.txt)
CURRENTSITEURL=`$WPCLI option get siteurl --path=$WPDIR --skip-plugins`

# Abort if the backup's siteurl doesn't match with the target
if [ "$BACKUPSITEURL" != "$CURRENTSITEURL" ]; then
    echo "Target URL does not match backup snapshot. Aborting."
    exit
fi

# Does the backup file contain the WP version number?
if [ ! -f "/tmp/$BACKUPFILE.core.txt" ]; then
    echo "Incomplete backup file: missing core.txt. Aborting."
    exit
fi

BACKUPVERSION=$(</tmp/$BACKUPFILE.core.txt)
CURRENTVERSION=`$WPCLI core version --path=$WPDIR --skip-plugins`

cd ${1%/}

# Restore core and switch it to appropriate branch, if needed
if [[ $? -ne 0 || ! -f "$WPDIR/.git" ]]; then
    echo "Restoring WP Core as a git module"
    /usr/bin/git --git-dir=$1/.git submodule update wp
fi

if [ "$BACKUPVERSION" != "$CURRENTVERSION" ]; then
    echo "Switching core/wp to version $BACKUPVERSION"
    #/usr/bin/git --git-dir=$WPDIR/.git --work-tree=$WPDIR checkout -b "$BACKUPFILE-$BACKUPVERSION" "tags/$BACKUPVERSION" 
else
    echo "wp/core: already at version $BACKUPVERSION"
fi

# Import the data file
read -n1 -p "Would you like to reset the database and import the data from your backup? [y/N] " RESET_DB
echo -e "\n"
if [[ $RESET_DB == "y" || $RESET_DB == "Y" ]]; then
    $WPCLI db reset --yes
    $WPCLI --path=$WPDIR db import /tmp/${BACKUPFILE}.sql
fi

# Switch all the plugins to the appropriate branch
echo "Analyzing plugins"
while IFS=, read -r SLUG BACKUPVERSION; do
    # Make sure that the remote repo exists
    if git ls-remote --exit-code $GITPATH/$SLUG.git &>/dev/null; then

        # If the folder doesn't exist, clone it from the remote repository
        if [[ ! -d "${1%/}/content/plugins/$SLUG/" && ! -z "$BACKUPVERSION" ]]; then
            echo "Restoring plugins/$SLUG"
            /usr/bin/git clone -b master $GITPATH/$SLUG.git ${1%/}/content/plugins/$SLUG
            /usr/bin/git --git-dir=${1%/}/content/plugins/$SLUG/.git --work-tree=${1%/}/content/plugins/$SLUG fetch --tags
        fi

        # Checkout the version associated with this backup, if needed
        if [ ! -z "$BACKUPVERSION" ]; then
            CURRENTVERSION=`$WPCLI plugin get $SLUG --path=$WPDIR --field=version --skip-plugins 2> /dev/null`
            EXITSTATUS=$?
            if [[ $EXITSTATUS -eq 0 && "$BACKUPVERSION" != "$CURRENTVERSION" ]]; then
                echo "Switching plugins/$SLUG to version $BACKUPVERSION"
                /usr/bin/git --git-dir=${1%/}/content/plugins/$SLUG/.git --work-tree=${1%/}/content/plugins/$SLUG checkout -b "$BACKUPFILE-$BACKUPVERSION" "tags/$BACKUPVERSION";
            elif [ $EXITSTATUS -ne 0 ]; then
                echo "plugins/$SLUG: current version cannot be determined, keeping current"
            else
                echo "plugins/$SLUG: already at version $BACKUPVERSION"
            fi
        fi

    # Remote repo not found
    else
        echo "Remote repo not found for $SLUG. Skipping."
    fi
done < /tmp/$BACKUPFILE.plugins.csv

# Switch all the themes to the appropriate branch
echo "Analyzing themes"
while IFS=, read -r SLUG BACKUPVERSION; do
    # Make sure that the remote repo exists
    if git ls-remote --exit-code $GITPATH/$SLUG.git &>/dev/null; then

        # If the folder doesn't exist, clone it from the remote repository
        if [[ ! -d "${1%/}/content/themes/$SLUG/" ]]; then
            echo "Restoring themes/$SLUG"
            /usr/bin/git clone -b master $GITPATH/$SLUG.git ${1%/}/content/themes/$SLUG
            /usr/bin/git --git-dir=${1%/}/content/themes/$SLUG/.git --work-tree=${1%/}/content/themes/$SLUG fetch --tags
        fi

        # Checkout the version associated with this backup, if needed
        if [ ! -z "$BACKUPVERSION" ]; then
            CURRENTVERSION=`$WPCLI theme get $SLUG --path=$WPDIR --field=version --skip-plugins 2> /dev/null`
            EXITSTATUS=$?
            if [[ $EXITSTATUS -eq 0 && "$BACKUPVERSION" != "$CURRENTVERSION" ]]; then
                echo "Switching themes/$SLUG to version $BACKUPVERSION"
                /usr/bin/git --git-dir=${1%/}/content/themes/$SLUG/.git --work-tree=${1%/}/content/themes/$SLUG checkout -b "$BACKUPFILE-$BACKUPVERSION" "tags/$BACKUPVERSION";
            elif [ $EXITSTATUS -ne 0 ]; then
                echo "themes/$SLUG: current version cannot be determined, keeping current"
            else
                echo "themes/$SLUG: already at version $BACKUPVERSION"
            fi
        fi

    # Remote repo not found
    else
        echo "Remote repo not found for $SLUG. Skipping."
    fi
done < /tmp/$BACKUPFILE.themes.csv

# Delete the folder with the uncompressed backup files
rm -rf /tmp/${BACKUPFILE}*

#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 plugin|theme slug|all"
  exit 1
fi

update_repo () {
  REPO_SLUG=${2%/}
  echo "Checking for updates for '$REPO_SLUG'. Please wait."
  WP_CLI_DRY_RUN=$(wp $1 update --dry-run --format=csv $REPO_SLUG)

  # Is a new version available?
  if [ -z "$WP_CLI_DRY_RUN" ]; then
    echo "Repository '$REPO_SLUG' already up-to-date. Nothing to do here."
    exit 1
  fi

  NEW_VERSION=$(echo "${WP_CLI_DRY_RUN##*$'\n'}" | rev | cut -d"," -f1  | rev)

  if [[ $3 != "quiet" ]]; then
    printf "A new version ($NEW_VERSION) is available for '$REPO_SLUG'. Would you like to proceed with the update? [Y/n] "
    read -r WP_CONFIRM_UPDATE
    if [[ $WP_CONFIRM_UPDATE == 'n' || $WP_CONFIRM_UPDATE == 'N' ]]; then
      exit 1
    fi
  fi

  REPO_DIR="$(/usr/local/bin/wp $1 path)/$REPO_SLUG"

  if [ -d "$REPO_DIR/.git" ]; then

    # Does this repo have an upstream branch?
    REPO_UPSTREAM_BRANCH=$(git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR rev-parse --verify --quiet upstream)

    if [ ! -z "$REPO_UPSTREAM_BRANCH" ]; then
      printf "This plugin is using an 'upstream' branch. Would you like to use it to save the new version? [Y/n] "
      read -r WP_CONFIRM_BRANCH
      if [[ $WP_CONFIRM_BRANCH == 'n' || $WP_CONFIRM_UPDATE == 'N' ]]; then
        exit 1
      fi

      REPO_TARGET_BRANCH="upstream"
    else
      REPO_TARGET_BRANCH="master"
    fi

    REPO_CURRENT_BRANCH=$(git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR symbolic-ref HEAD --short 2>/dev/null)
	
    if [ "$REPO_CURRENT_BRANCH" != "$REPO_TARGET_BRANCH" ]; then
      git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR checkout $REPO_TARGET_BRANCH
    fi
  
    # Move git folder and .gitignore somewhere else
    echo "Saving git folder"
    if [ -d $REPO_DIR/.git ]; then
      mv "$REPO_DIR/.git" "/tmp/.git-$REPO_SLUG"
    fi

    if [ -f $REPO_DIR/.gitignore ]; then
      mv "$REPO_DIR/.gitignore" "/tmp/.gitignore-$REPO_SLUG"
    fi
  else
    echo "No .git folder found for '$REPO_SLUG'. Updating $1 without tracking changes."
  fi  

  # Update the plugin/theme
  WP_CLI_UPDATE=$(wp $1 update --format=csv $REPO_SLUG)
  if [[ $WP_CLI_UPDATE = *Error* ]]; then
    echo "There was an error updating $REPO_SLUG to version $NEW_VERSION. Aborting."

    if [ -d /tmp/.git-$REPO_SLUG ]; then
      # Restore Git folder
      mv "/tmp/.git-$REPO_SLUG" "$REPO_DIR/.git"
    fi

    if [ -f /tmp/.gitignore-$REPO_SLUG ]; then
      # Restore gitignore file
      mv "/tmp/.gitignore-$REPO_SLUG" "$REPO_DIR/.gitignore"
    fi

    exit 2
  else
    echo "${1^} $REPO_SLUG successfully updated."
  fi

  # Move git stuff back
  if [ -f /tmp/.gitignore-$REPO_SLUG ]; then
    mv "/tmp/.gitignore-$REPO_SLUG" "$REPO_DIR/.gitignore"
  fi

  if [ -d /tmp/.git-$REPO_SLUG ]; then
    echo "Restoring git folder and committing changes to '$REPO_TARGET_BRANCH' branch"
    mv "/tmp/.git-$REPO_SLUG" "$REPO_DIR/.git"
    git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR add -u .
    git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR add .
    git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR commit -m "Version $NEW_VERSION"
	
    if [ "$REPO_TARGET_BRANCH" == "master" ]; then
      git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR tag $NEW_VERSION
    else
      git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR tag $REPO_TARGET_BRANCH/$NEW_VERSION
    fi

    # Switch back to the original branch
    if [ "$REPO_CURRENT_BRANCH" != "$REPO_TARGET_BRANCH" ]; then
      git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR checkout $REPO_CURRENT_BRANCH
    fi

    # Update the repository and commit the changes
    if [[ $3 != "quiet" ]]; then
      printf "Would you like to push the update to the remote git repo (branch '$REPO_TARGET_BRANCH')? [Y/n] "
      read -r WP_CONFIRM_PUSH
      if [[ $WP_CONFIRM_PUSH == 'n' || $WP_CONFIRM_PUSH == 'N' ]]; then
        exit 1
      fi
    fi

    git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR push origin $REPO_TARGET_BRANCH
    git --git-dir=$REPO_DIR/.git --work-tree=$REPO_DIR push --tags
  fi
}

if [[ $2 == "all" ]]; then
  SLUG_LIST=$(wp $1 list --update=available --fields=name --format=csv | sed "1 d")
  if [ ! -z "$SLUG_LIST" ]; then
    echo "The following repos have available updates:"
    echo "$SLUG_LIST"
    while IFS= read -r A_SLUG; do
      update_repo $1 $A_SLUG quiet
    done <<< "$SLUG_LIST"
  else
    echo "No available updates found."
  fi
else
  update_repo $1 $2 verbose
fi

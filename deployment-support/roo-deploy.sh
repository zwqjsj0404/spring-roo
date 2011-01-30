#/bin/shell

usage() {
cat << EOF
usage: $0 options

OPTIONS:
    -c CMD   Command name (CMD = assembly|deploy|next)
    -n VER   Next version number (for "next" command)
    -s ID    Add suffix to assembly filename (for "assembly" command)
    -d       Dry run (for "deploy" command)
    -v       Verbose
    -h       Show this message

COMMAND NAMES:
    "assembly" -> creates a release ZIP (use after "mvn site")
    "deploy" -> deploys the release ZIP (use after "assembly")
    "next" -> modifies Roo version numbers to that given by -n

DESCRIPTION:
    Automates building deployment ZIPs and allow later deployment.
    Use "-c deploy -vd" to see what will happen, but without uploading.
    Use "-c next -n 3.4.5.RC1" to change next version to 3.4.5.RC1.
    Use "-c deploy -s _12-24" to add "_12-24" to the assembly filename.

REQUIRES:
    s3cmd (ls should list the SpringSource buckets)
    ~/.m2/settings.xml contains a <gpg.passphrase> for the GPG key
EOF
}

log() {
    if [ "$VERBOSE" = "1" ]; then
        echo "$@"
    fi
}

l_error() {
    echo "### ERROR: $@"
}

s3_execute() {
    type -P s3cmd &>/dev/null || { l_error "s3cmd not found. Aborting." >&2; exit 1; }
    S3CMD_OPTS=''
    if [ "$DRY_RUN" = "1" ]; then
        S3CMD_OPTS="$S3CMD_OPTS --dry-run"
    fi
    if [ "$VERBOSE" = "1" ]; then
        S3CMD_OPTS="$S3CMD_OPTS -v"
    fi
    s3cmd $S3CMD_OPTS $@
    EXITED=$?
    if [[ ! "$EXITED" = "0" ]]; then
        l_error "s3cmd failed (exit code $EXITED)." >&2; exit 1;
    fi
}

COMMAND=
NEXT=
VERBOSE='0'
DRY_RUN='0'
SUFFIX=''
while getopts "s:c:n:vdh" OPTION
do
    case $OPTION in
        h)
            usage
            exit 1
            ;;
        c)
            COMMAND=$OPTARG
            ;;
        n)
            NEXT=$OPTARG
            ;;
        s)
            SUFFIX=$OPTARG
            ;;
        d)
            DRY_RUN=1
            ;;
        v)
            VERBOSE=1
            ;;
        ?)
            usage
            exit
            ;;
    esac
done

if [[ -z $COMMAND ]]; then
    usage
    exit 1
fi

if [[ "$COMMAND" = "assembly" ]] || [[ "$COMMAND" = "deploy" ]] || [[ "$COMMAND" = "next" ]]; then
    log "Command........: $COMMAND"
else
    usage
    exit 1
fi

type -P gpg &>/dev/null || { l_error "gpg not found. Aborting." >&2; exit 1; }

PRG="$0"

while [ -h "$PRG" ]; do
    ls=`ls -ld "$PRG"`
    link=`expr "$ls" : '.*-> \(.*\)$'`
    if expr "$link" : '/.*' > /dev/null; then
        PRG="$link"
    else
        PRG=`dirname "$PRG"`/"$link"
    fi
done
ROO_HOME=`dirname "$PRG"`

# Absolute path
ROO_HOME=`cd "$ROO_HOME/.." ; pwd`
log "Location.......: $ROO_HOME"

# Compute version and Git-related info
GIT_HASH=`git log "--pretty=format:%H" -n1 $ROO_HOME`
log "Git Hash.......: $GIT_HASH"
GIT_TAG=`git tag -l "*\.*\.*\.*" $ROO_HOME | tail -n 1`
log "Git Tag........: $GIT_TAG"
VERSION=`grep "<version>" $ROO_HOME/pom.xml | head -n 1 | sed 's/<version>//' | sed 's/<\/version>//' | sed 's/ //g'`
log "Version........: $VERSION"
SHORT_VERSION=`echo $VERSION | sed 's/\([0-9].[0-9].[0-9]\).*\.BUILD-SNAPSHOT/\1/'`
log "Short Version..: $SHORT_VERSION"

# Determine the version as required by the AWS dist.springframework.org "x-amz-meta-release.type" header
case $VERSION in
    *BUILD-SNAPSHOT) TYPE=snapshot;;
    *RC*) TYPE=milestone;;
    *M*) TYPE=milestone;;
    *RELEASE) TYPE=release;;
    *) l_error "Unsupported release type ($VERSION). Aborting." >&2; exit 1;;
esac
log "Release Type...: $TYPE"

# Product release identifier
RELEASE_IDENTIFIER="spring-roo-$VERSION"
log "Release ID.....: $RELEASE_IDENTIFIER"

# File locations
TARGET_DIR="$ROO_HOME/target/roo-deploy"
log "Target Dir.....: $TARGET_DIR"
WORK_DIR="$ROO_HOME/target/roo-deploy/work/$RELEASE_IDENTIFIER"
log "Work Dir.......: $WORK_DIR"
DIST_DIR="$ROO_HOME/target/roo-deploy/dist"
log "Output Dir.....: $DIST_DIR"
ASSEMBLY_ZIP="$DIST_DIR/$RELEASE_IDENTIFIER$SUFFIX.zip"
log "Assembly Zip...: $ASSEMBLY_ZIP"
ASSEMBLY_SHA="$DIST_DIR/$RELEASE_IDENTIFIER$SUFFIX.zip.sha1"
log "Assembly SHA...: $ASSEMBLY_SHA"
ASSEMBLY_ASC="$DIST_DIR/$RELEASE_IDENTIFIER$SUFFIX.zip.asc"
log "Assembly ASC...: $ASSEMBLY_ASC"

if [[ "$COMMAND" = "assembly" ]]; then
    if [ ! -f $ROO_HOME/target/all/org.springframework.roo.bootstrap-*.jar ]; then
        l_error "JARs missing; you must run mvn package before attempting assembly"
        exit 1
    fi
    if [ ! -f $ROO_HOME/deployment-support/target/site/reference/pdf/spring-roo-docs.pdf ]; then
        l_error "Site docs missing; you must run mvn site before attempting assembly"
        exit 1
    fi
    log "Cleaning $TARGET_DIR"
    rm -rf $TARGET_DIR
    log "Cleaning $WORK_DIR"
    rm -rf $WORK_DIR

    # Create a directory structure to match the desired assembly ZIP output
    mkdir -p $WORK_DIR/annotations
    mkdir -p $WORK_DIR/bin
    mkdir -p $WORK_DIR/bundle
    mkdir -p $WORK_DIR/conf
    mkdir -p $WORK_DIR/docs/pdf
    mkdir -p $WORK_DIR/docs/html
    mkdir -p $WORK_DIR/legal
    cp $ROO_HOME/annotations/target/*-$VERSION.jar $WORK_DIR/annotations
    cp $ROO_HOME/target/all/*.jar $WORK_DIR/bundle
    rm $WORK_DIR/bundle/*jsch*.jar
    rm $WORK_DIR/bundle/*jgit*.jar
    rm $WORK_DIR/bundle/*git*.jar
    rm $WORK_DIR/bundle/*op4j*.jar
    mv $WORK_DIR/bundle/org.springframework.roo.bootstrap-*.jar $WORK_DIR/bin
    mv $WORK_DIR/bundle/org.apache.felix.framework-*.jar $WORK_DIR/bin
    cp $ROO_HOME/bootstrap/src/main/bin/* $WORK_DIR/bin
    chmod 775 $WORK_DIR/bin/*.sh
    cp $ROO_HOME/bootstrap/src/main/conf/* $WORK_DIR/conf
    cp $ROO_HOME/bootstrap/readme.txt $WORK_DIR/
    cp `find $ROO_HOME -iname legal-\*.txt` $WORK_DIR/legal
    cp -r $ROO_HOME/deployment-support/target/site/reference/pdf $WORK_DIR/docs/pdf
    cp -r $ROO_HOME/deployment-support/target/site/reference/html $WORK_DIR/docs/html

    # Prepare to write the ZIP
    log "Cleaning $DIST_DIR" 
    rm -rf $DIST_DIR
    mkdir -p $DIST_DIR

    # Change directories to avoid absolute paths
    pushd $WORK_DIR/.. &>/dev/null
    log "Running ZIP from `pwd`"
    ZIP_OPTS='-q'
    if [ "$VERBOSE" = "1" ]; then
        ZIP_OPTS='-v'
    fi
    log "ZIP command: zip $ZIP_OPTS $ASSEMBLY_ZIP -r $RELEASE_IDENTIFIER"
    zip $ZIP_OPTS $ASSEMBLY_ZIP -r $RELEASE_IDENTIFIER
    EXITED=$?
    if [[ ! "$EXITED" = "0" ]]; then
        l_error "ZIP process failed (zip exit code $EXITED)." >&2; exit 1;
    fi

    # Hash the ZIP
    pushd $DIST_DIR &>/dev/null
    sha1sum *.zip > $ASSEMBLY_SHA

    # Sign the ZIP
    grep "<gpg.passphrase>" ~/.m2/settings.xml &>/dev/null
    EXITED=$?
    if [[ ! "$EXITED" = "0" ]]; then
        l_error "~/.m2/settings.xml does not contain a <gpg.passphrase> (grep exit code $EXITED)." >&2; exit 1;
    fi
    PASSPHRASE=`grep "<gpg.passphrase>" ~/.m2/settings.xml | sed 's/<gpg.passphrase>//' | sed 's/<\/gpg.passphrase>//' | sed 's/ //g'`
    GPG_OPTS='-q'
    if [ "$VERBOSE" = "1" ]; then
        GPG_OPTS='-v'
    fi
    echo "$PASSPHRASE" | gpg $GPG_OPTS --batch --passphrase-fd 0 -a --output $ASSEMBLY_ASC --detach-sign $ASSEMBLY_ZIP
    EXITED=$?
    if [[ ! "$EXITED" = "0" ]]; then
        l_error "GPG process failed (gpg exit code $EXITED)." >&2; exit 1;
    fi
    
    # Return to the original directory
    popd &>/dev/null
    popd &>/dev/null
fi

if [[ "$COMMAND" = "deploy" ]]; then
    if [ ! -f $ASSEMBLY_ZIP ]; then
        l_error "Unable to find $ASSEMBLY_ZIP"
        exit 1
    fi
    if [ ! -f $ASSEMBLY_SHA ]; then
        l_error "Unable to find $ASSEMBLY_SHA"
        exit 1
    fi
    ZIP_FILENAME=`basename $ASSEMBLY_ZIP`
    PROJECT_NAME="Spring Roo"
    AWS_PATH="s3://dist.springframework.org/$TYPE/ROO/"
    log "AWS bundle.ver.: $VERSION"
    log "AWS rel.type...: $TYPE"
    log "AWS pkg.f.name.: $ZIP_FILENAME"
    log "AWS proj.name..: $PROJECT_NAME"
    log "AWS Path.......: $AWS_PATH"
    s3_execute put --acl-public \
        "--add-header=x-amz-meta-bundle.version:$VERSION" \
        "--add-header=x-amz-meta-release.type:$TYPE" \
        "--add-header=x-amz-meta-package.file.name:$ZIP_FILENAME" \
        "--add-header=x-amz-meta-project.name:$PROJECT_NAME" \
        $ASSEMBLY_ZIP $AWS_PATH
    s3_execute put --acl-public $ASSEMBLY_SHA $AWS_PATH
    s3_execute put --acl-public $ASSEMBLY_ASC $AWS_PATH

    # Clean up old snapshot releases (if we just performed a snapshot release)
    if [[ "$TYPE" = "snapshot" ]]; then
        s3_execute ls s3://dist.springframework.org/snapshot/ROO/ | grep '.zip$' | cut -c "30-"> /tmp/dist_all.txt
        tail -n 5 /tmp/dist_all.txt > /tmp/dist_to_keep.txt
        cat /tmp/dist_all.txt /tmp/dist_to_keep.txt | sort | uniq -u > /tmp/dist_to_delete.txt
        for url in `cat /tmp/dist_to_delete.txt`; do
            s3_execute del "$url"
            s3_execute del "$url.asc"
            s3_execute del "$url.sha1"
        done
        rm /tmp/dist_*.txt
    fi
fi

if [[ "$COMMAND" = "next" ]]; then
    # We only need to change the _first_ <version> element in each pom.xml to complete a version update
    find $ROO_HOME -iname pom.xml -print0 | while read -d $'\0' file
    do
        log "Updating $file"
        sed -i "0,/<version>.*<\/version>/s//<version>$NEXT<\/version>/" $file
    done
    log "Updating project templates"
    sed -i "s/<roo.version>.*<\/roo.version>/<roo.version>$NEXT<\/roo.version>/" `find $ROO_HOME -iname *-template.xml`
    log "Updating documentation"
    sed -i "s/<releaseinfo>.*<\/releaseinfo>/<releaseinfo>$NEXT<\/releaseinfo>/" $ROO_HOME/deployment-support/src/site/docbook/reference/index.xml
fi


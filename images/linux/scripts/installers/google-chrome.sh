#!/bin/bash -e
################################################################################
##  File:  google-chrome.sh
##  Desc:  Installs google-chrome, chromedriver and chromium
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

function GetChromiumRevision {
    CHROME_VERSION=$1

    # Get the required Chromium revision corresponding to the Chrome version
    URL="https://omahaproxy.appspot.com/deps.json?version=${CHROME_VERSION}"
    REVISION=$(curl -s $URL | jq -r '.chromium_base_position')

    # Temporarily hardcode revision as both requests
    # for 115.0.5790.102 and 115.0.5790.98 return old incorrect revision
    if [ $REVISION -eq "1583" ]; then
       REVISION="1134878"
    fi

    # Some Google Chrome versions are based on Chromium revisions for which a (usually very old) Chromium release with the same number exist. So far this has heppened with 4 digits long Chromium revisions (1060, 1086).
    # Use the previous Chromium release when this happens to avoid downloading and installing very old Chromium releases that would break image build because of incompatibilities.
    # First reported with: https://github.com/actions/runner-images/issues/5256
    if [ ${#REVISION} -le 4 ]; then
      CURRENT_REVISIONS=$(curl -s "https://omahaproxy.appspot.com/all.json?os=linux&channel=stable")
      PREVIOUS_VERSION=$(echo "$CURRENT_REVISIONS" | jq -r '.[].versions[].previous_version')
      URL="https://omahaproxy.appspot.com/deps.json?version=${PREVIOUS_VERSION}"
      REVISION=$(curl -s $URL | jq -r '.chromium_base_position')
    fi
    # Take the first part of the revision variable to search not only for a specific version,
    # but also for similar ones, so that we can get a previous one if the required revision is not found
    FIRST_PART_OF_REVISION=${REVISION:0:${#REVISION}/2}
    FIRST_PART_OF_PREVIOUS_REVISION=$(expr $FIRST_PART_OF_REVISION - 1)
    URL="https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o?delimiter=/&prefix=Linux_x64"
    # Revision can include a hash instead of a number. Need to filter it out https://github.com/actions/runner-images/issues/5256
    VERSIONS=$((curl -s $URL/${FIRST_PART_OF_REVISION} | jq -r '.prefixes[]' && curl -s $URL/${FIRST_PART_OF_PREVIOUS_REVISION} | jq -r '.prefixes[]') | grep -E "Linux_x64\/[0-9]+\/"| cut -d "/" -f 2 | sort --version-sort)

    # If required Chromium revision is not found in the list
    # we should have to decrement the revision number until we find one.
    # This is mentioned in the documentation we use for this installation:
    # https://www.chromium.org/getting-involved/download-chromium
    RIGHT_REVISION=$(echo $VERSIONS | cut -f 1 -d " ")
    for version in $VERSIONS; do
        if [ $REVISION -lt $version ]; then
            echo $RIGHT_REVISION
            return
        fi
        RIGHT_REVISION=$version
    done
    echo $RIGHT_REVISION
}

# Download and install Google Chrome
CHROME_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
CHROME_DEB_NAME="google-chrome-stable_current_amd64.deb"
download_with_retries $CHROME_DEB_URL "/tmp" "${CHROME_DEB_NAME}"
apt install "/tmp/${CHROME_DEB_NAME}" -f
echo "CHROME_BIN=/usr/bin/google-chrome" | tee -a /etc/environment

# Remove Google Chrome repo
rm -f /etc/cron.daily/google-chrome /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.list.save

# Parse Google Chrome version
FULL_CHROME_VERSION=$(google-chrome --product-version)
CHROME_VERSION=${FULL_CHROME_VERSION%.*}
echo "Chrome version is $FULL_CHROME_VERSION"

# Determine the download url for chromedriver
CHROME_VERSIONS_JSON=$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/latest-patch-versions-per-build-with-downloads.json)
CHROMEDRIVER_VERSION=$(echo $CHROME_VERSIONS_JSON | jq -r '.builds["'"$CHROME_VERSION"'"].version')
CHROMEDRIVER_URL=$(echo $CHROME_VERSIONS_JSON | jq -r '.builds["'"$CHROME_VERSION"'"].downloads.chromedriver[] | select(.platform=="linux64").url')

# Download and unpack the latest release of chromedriver
echo "Installing chromedriver version $CHROMEDRIVER_VERSION"
download_with_retries $CHROMEDRIVER_URL "/tmp" "chromedriver_linux64.zip"
unzip -qq /tmp/chromedriver_linux64.zip -d /usr/local/share

CHROMEDRIVER_DIR="/usr/local/share/chromedriver-linux64"
CHROMEDRIVER_BIN="$CHROMEDRIVER_DIR/chromedriver"
chmod +x $CHROMEDRIVER_BIN
ln -s "$CHROMEDRIVER_BIN" /usr/bin/
echo "CHROMEWEBDRIVER=$CHROMEDRIVER_DIR" | tee -a /etc/environment

# Download and unpack Chromium
# Get Chromium version corresponding to the Google Chrome version
REVISION=$(GetChromiumRevision $FULL_CHROME_VERSION)

ZIP_URL="https://www.googleapis.com/download/storage/v1/b/chromium-browser-snapshots/o/Linux_x64%2F${REVISION}%2Fchrome-linux.zip?alt=media"
ZIP_FILE="${REVISION}-chromium-linux.zip"

CHROMIUM_DIR="/usr/local/share/chromium"
CHROMIUM_BIN="$CHROMIUM_DIR/chrome-linux/chrome"

# Download and unzip Chromium archive
download_with_retries $ZIP_URL "/tmp" $ZIP_FILE
mkdir $CHROMIUM_DIR
unzip -qq /tmp/${ZIP_FILE} -d $CHROMIUM_DIR

ln -s $CHROMIUM_BIN /usr/bin/chromium
ln -s $CHROMIUM_BIN /usr/bin/chromium-browser

invoke_tests "Browsers" "Chrome"
invoke_tests "Browsers" "Chromium"
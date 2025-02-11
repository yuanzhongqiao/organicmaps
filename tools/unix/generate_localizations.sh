#!/bin/bash
set -euxo pipefail

OMIM_PATH="$(dirname "$0")/../.."

# Use correct ruby version from homebrew for MacOS
case $OSTYPE in
  darwin*)
    if [ -x /usr/local/opt/ruby/bin/ruby ]; then
      PATH="/usr/local/opt/ruby/bin:$PATH"
    elif [ -x "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/ruby/bin/ruby" ]; then
      PATH="${HOMEBREW_PREFIX:-/opt/homebrew}/opt/ruby/bin:$PATH"
    else
      echo 'Please install Homebrew ruby by running "brew install ruby"'
      exit 1
    fi ;;
  *)
    if [ ! -x "$(which ruby)" ]; then
      echo "Please, install ruby (https://www.ruby-lang.org/en/documentation/installation/)"
      exit 1
    fi ;;
esac

TWINE_SUBMODULE=tools/twine
TWINE_PATH="$OMIM_PATH/$TWINE_SUBMODULE"
GEM_PATH="$OMIM_PATH/$TWINE_SUBMODULE/gem"

if [ ! -e "$TWINE_PATH/twine" ]; then
  echo "You need to have twine submodule present to run this script"
  echo "Try 'git submodule update --init --recursive'"
  exit 1
fi

# Always run gem install to use the latest version
gem install twine --install-dir $GEM_PATH

TWINE_COMMIT="$(git -C $TWINE_SUBMODULE rev-parse HEAD)"
TWINE_GEM="twine-$TWINE_COMMIT.gem"

# If twine gem does not exist, then install it
if [ ! -f "$GEM_PATH/$TWINE_GEM" ]; then
  echo "Building & installing twine gem..."
  (
    cd "$TWINE_PATH" \
    && rm -f ./*.gem \
    && gem build --output "$TWINE_GEM" \
    && gem install --user-install "$TWINE_GEM"
  )
fi

# Validate and format/sort strings files.
STRINGS_UTILS="$OMIM_PATH/tools/python/strings_utils.py"
"$STRINGS_UTILS" --validate --output
"$STRINGS_UTILS" --types-strings --validate --output

# Check for unused strings.
CLEAN_STRINGS="$OMIM_PATH/tools/python/clean_strings_txt.py"
"$CLEAN_STRINGS" --validate

# Generate android/iphone/jquery localization files from strings files.
TWINE="$(gem contents twine | grep -m 1 bin/twine)"
STRINGS_PATH="$OMIM_PATH/data/strings"

MERGED_FILE="$(mktemp)"
cat "$STRINGS_PATH"/{strings,types_strings}.txt> "$MERGED_FILE"

# TODO: Add validate-strings-file call to check for duplicates (and avoid Android build errors) when tags are properly set.
"$TWINE" generate-all-localization-files --include translated --format android --untagged --tags android "$MERGED_FILE" "$OMIM_PATH/android/app/src/main/res/"
"$TWINE" generate-all-localization-files --format apple --untagged --tags ios "$MERGED_FILE" "$OMIM_PATH/iphone/Maps/LocalizedStrings/"
"$TWINE" generate-all-localization-files --format apple-plural --untagged --tags ios "$MERGED_FILE" "$OMIM_PATH/iphone/Maps/LocalizedStrings/"
"$TWINE" generate-all-localization-files --format apple --file-name InfoPlist.strings "$OMIM_PATH/iphone/plist.txt" "$OMIM_PATH/iphone/Maps/LocalizedStrings/"
"$TWINE" generate-all-localization-files --format jquery "$OMIM_PATH/data/countries_names.txt" "$OMIM_PATH/data/countries-strings/"
"$TWINE" generate-all-localization-files --format jquery "$OMIM_PATH/data/strings/sound.txt" "$OMIM_PATH/data/sound-strings/"

rm "$MERGED_FILE"

# Generate list of languages and add list in gradle.properties to be used in build.gradle in resConfig
SUPPORTED_LOCALIZATIONS="supportedLocalizations="$(sed -nEe "s/ +([a-zA-Z]{2}(-[a-zA-Z]{2,})?) = .*$/\1/p" "data/strings/strings.txt" | sort -u | tr '\n' ',' | sed -e 's/-/_/g' -e 's/,$//')
# Chinese locales should correspond to Android codes.
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/zh_Hans/zh}
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/zh_Hant/zh_HK,zh_MO,zh_TW}
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/he/iw}
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/id/in}
GRADLE_PROPERTIES="$OMIM_PATH/android/gradle.properties"
if [ "$SUPPORTED_LOCALIZATIONS" != "$(grep supportedLocalizations "$GRADLE_PROPERTIES")" ]; then
  sed -i.bak 's/supportedLocalizations.*/'"$SUPPORTED_LOCALIZATIONS"'/' "$GRADLE_PROPERTIES"
  rm "$GRADLE_PROPERTIES.bak"
fi

# Generate locales_config.xml to allow users change app's language on Android 13+
LOCALES_CONFIG="$OMIM_PATH/android/app/src/main/res/xml/locales_config.xml"
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/supportedLocalizations=/en,}
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS/,en,/,}
SUPPORTED_LOCALIZATIONS=${SUPPORTED_LOCALIZATIONS//_/-}
LOCALES_CONTENT='<?xml version="1.0" encoding="utf-8"?>
<locale-config xmlns:android="http://schemas.android.com/apk/res/android">'
set +x
for lang in ${SUPPORTED_LOCALIZATIONS//,/ }; do
  LOCALES_CONTENT="$LOCALES_CONTENT"$'\n'"    <locale android:name=\"$lang\" />"
done
LOCALES_CONTENT="$LOCALES_CONTENT"$'\n''</locale-config>'
if [ "$LOCALES_CONTENT" != "$(cat "$LOCALES_CONFIG")" ]; then
  echo "$LOCALES_CONTENT" > "$LOCALES_CONFIG"
  echo Updated "$LOCALES_CONFIG" file
fi

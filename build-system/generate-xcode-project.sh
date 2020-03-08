#!/bin/sh

set -e

BAZEL="$(which bazel)"
if [ "$BAZEL" = "" ]; then
	echo "bazel not found in PATH"
	exit 1
fi

XCODE_VERSION=$(cat "build-system/xcode_version")
INSTALLED_XCODE_VERSION=$(echo `plutil -p \`xcode-select -p\`/../Info.plist | grep -e CFBundleShortVersionString | sed 's/[^0-9\.]*//g'`)

if [ "$INSTALLED_XCODE_VERSION" != "$XCODE_VERSION" ]; then
	echo "Xcode $XCODE_VERSION required, $INSTALLED_XCODE_VERSION installed (at $(xcode-select -p))"
	exit 1
fi

EXPECTED_VARIABLES=(\
	BUILD_NUMBER \
	APP_VERSION \
	BUNDLE_ID \
	DEVELOPMENT_TEAM \
	API_ID \
	API_HASH \
	APP_CENTER_ID \
	IS_INTERNAL_BUILD \
	IS_APPSTORE_BUILD \
	APPSTORE_ID \
	APP_SPECIFIC_URL_SCHEME \
)

MISSING_VARIABLES="0"
for VARIABLE_NAME in ${EXPECTED_VARIABLES[@]}; do
	if [ "${!VARIABLE_NAME}" = "" ]; then
		echo "$VARIABLE_NAME not defined"
		MISSING_VARIABLES="1"
	fi
done
if [ "$MISSING_VARIABLES" == "1" ]; then
	exit 1
fi

GEN_DIRECTORY="build-input/gen/project"
rm -rf "$GEN_DIRECTORY"
mkdir -p "$GEN_DIRECTORY"

pushd "build-system/tulsi"
"$BAZEL" build //:tulsi --xcode_version="$XCODE_VERSION"
popd

TULSI_DIRECTORY="build-input/gen/project"
TULSI_APP="build-input/gen/project/Tulsi.app"
TULSI="$TULSI_APP/Contents/MacOS/Tulsi"
mkdir -p "$TULSI_DIRECTORY"

unzip -oq "build-system/tulsi/bazel-bin/tulsi.zip" -d "$TULSI_DIRECTORY"

CORE_COUNT=$(sysctl -n hw.logicalcpu)
CORE_COUNT_MINUS_ONE=$(expr ${CORE_COUNT} \- 1)

BAZEL_OPTIONS=(\
	--features=swift.use_global_module_cache \
	--spawn_strategy=standalone \
	--strategy=SwiftCompile=standalone \
	--features=swift.enable_batch_mode \
	--swiftcopt=-j${CORE_COUNT_MINUS_ONE} \
)

if [ "$BAZEL_CACHE_DIR" != "" ]; then
	BAZEL_OPTIONS=("${BAZEL_OPTIONS[@]}" --disk_cache="$(echo $BAZEL_CACHE_DIR | sed -e 's/[\/&]/\\&/g')")
fi 

"$TULSI" -- \
	--verbose \
	--create-tulsiproj Telegram \
	--workspaceroot ./ \
	--bazel "$BAZEL" \
	--outputfolder "$GEN_DIRECTORY" \
	--target Telegram:Telegram \
	--target Telegram:Main \
	--target Telegram:Lib \

PATCH_OPTIONS="BazelBuildOptionsDebug BazelBuildOptionsRelease"
for NAME in $PATCH_OPTIONS; do
	sed -i "" -e '1h;2,$H;$!d;g' -e 's/\("'"$NAME"'" : {\n[ ]*"p" : "$(inherited)\)/\1'" ${BAZEL_OPTIONS[*]}"'/' "$GEN_DIRECTORY/Telegram.tulsiproj/Configs/Telegram.tulsigen"
done

sed -i "" -e '1h;2,$H;$!d;g' -e 's/\("sourceFilters" : \[\n[ ]*\)"\.\/\.\.\."/\1"Telegram\/...", "submodules\/..."/' "$GEN_DIRECTORY/Telegram.tulsiproj/Configs/Telegram.tulsigen"

"$TULSI" -- \
	--verbose \
	--genconfig "$GEN_DIRECTORY/Telegram.tulsiproj:Telegram" \
	--bazel "$BAZEL" \
	--outputfolder "$GEN_DIRECTORY" \

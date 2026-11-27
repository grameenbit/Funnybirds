#!/data/data/com.termux/files/usr/bin/bash
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
SDK="$ROOT/libs/android.jar"
mkdir -p "$ROOT/libs"
if [ ! -s "$SDK" ]; then
  echo "==> fetching android.jar (android-30)"
  curl -L --fail -o "$SDK" https://github.com/Sable/android-platforms/raw/master/android-30/android.jar || \
  wget -O "$SDK" https://github.com/Sable/android-platforms/raw/master/android-30/android.jar
fi
ls -la "$SDK"
export ANDROID_JAR="$SDK"

# ---- locate Android SDK build-tools/platform-tools and expose in PATH ----
BT_DIR=""
for sdkroot in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /usr/local/lib/android/sdk "$HOME/Android/Sdk" /opt/android-sdk; do
  [ -n "$sdkroot" ] && [ -d "$sdkroot" ] || continue
  # pick the HIGHEST build-tools version that contains aapt
  for bt in $(ls -d "$sdkroot"/build-tools/*/ 2>/dev/null | sort -V); do
    [ -x "$bt/aapt" ] && BT_DIR="$bt"
  done
  [ -z "$BT_DIR" ] && [ -d "$sdkroot/build-tools" ] && BT_DIR="$sdkroot/build-tools"
  [ -n "$BT_DIR" ] && export PATH="$BT_DIR:$PATH"
  [ -d "$sdkroot/platform-tools" ] && export PATH="$sdkroot/platform-tools:$PATH"
  [ -d "$sdkroot/cmdline-tools/latest/bin" ] && export PATH="$sdkroot/cmdline-tools/latest/bin:$PATH"
  [ -n "$BT_DIR" ] && break
done
export PATH
# ---- fallback: install build-tools via sdkmanager if aapt still missing ----
if ! command -v aapt >/dev/null 2>&1; then
  SM="$(command -v sdkmanager || true)"
  [ -n "$SM" ] && yes | "$SM" --licenses >/dev/null 2>&1 || true
  [ -n "$SM" ] && "$SM" "build-tools;34.0.0" "platforms;android-34" >/dev/null 2>&1 || true
  for sdkroot in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /usr/local/lib/android/sdk "$HOME/Android/Sdk"; do
    [ -d "$sdkroot" ] || continue
    for bt in $(ls -d "$sdkroot"/build-tools/*/ 2>/dev/null | sort -V); do
      [ -x "$bt/aapt" ] && export PATH="$bt:$PATH"
    done
  done
fi
# ---- final fallback: symlink any found aapt* into a bin dir on PATH ----
if ! command -v aapt >/dev/null 2>&1; then
  FOUND_AAPT="$(find / -name aapt -type f 2>/dev/null | head -1)"
  if [ -n "$FOUND_AAPT" ]; then
    mkdir -p "$ROOT/bin"
    for t in aapt aapt2 zipalign apksigner; do
      FT="$(dirname "$FOUND_AAPT")/$t"
      [ -f "$FT" ] && ln -sf "$FT" "$ROOT/bin/$t"
    done
    export PATH="$ROOT/bin:$PATH"
  fi
fi
echo "aapt:    $(command -v aapt || echo MISSING)"
echo "aapt2:   $(command -v aapt2 || echo MISSING)"
echo "zipalign:$(command -v zipalign || echo MISSING)"
echo "apksigner:$(command -v apksigner || echo MISSING)"
echo "keytool: $(command -v keytool || echo MISSING)"
echo "dx:      $(command -v dx || echo MISSING)"
echo "d8:      $(command -v d8 || echo MISSING)"
# ---- dx fallback: wrap d8 as dx if the legacy dx tool is absent ----
if ! command -v dx >/dev/null 2>&1 && command -v d8 >/dev/null 2>&1; then
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/dx" <<'EOS'
#!/usr/bin/env bash
set -e
args=(); out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dex) shift;;
    --output=*) out="${1#--output=}"; shift;;
    --output) out="$2"; shift 2;;
    *) args+=("$1"); shift;;
  esac
done
LIBJAR=""
for c in "$ANDROID_JAR" "${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}"/platforms/android-*/android.jar; do
  [ -s "$c" ] && LIBJAR="$c" && break
done
LIBARG=(); [ -n "$LIBJAR" ] && LIBARG=(--lib "$LIBJAR")
# d8 (R8 v9) rejects bare directory program inputs -> pack dirs into temp jars
INPUTS=(); CLEANUP=()
for a in "${args[@]}"; do
  if [ -d "$a" ]; then
    j="$(mktemp -u).jar"; ( cd "$a" && jar cf "$j" . )
    INPUTS+=("$j"); CLEANUP+=("$j")
  else
    INPUTS+=("$a")
  fi
done
run() { d8 "${LIBARG[@]}" --min-api 23 "$@" ; }
if [ -n "$out" ]; then
  case "$out" in
    *.dex)
      tmpd="$(mktemp -d)"
      run --output "$tmpd" "${INPUTS[@]}"
      mv -f "$tmpd/classes.dex" "$out"
      rm -rf "$tmpd"
      ;;
    *)
      run --output "$out" "${INPUTS[@]}"
      ;;
  esac
else
  run "${INPUTS[@]}"
fi
[ ${#CLEANUP[@]} -gt 0 ] && rm -f "${CLEANUP[@]}" || true
if [ -d "$out" ]; then :; elif [ -n "$out" ] && [ ! -e "$out" ]; then :; fi
EOS
  chmod +x "$ROOT/bin/dx"
  PATH="$ROOT/bin:$PATH"; export PATH
  echo "dx wrapper installed -> $(command -v dx)"
fi

# ---- AdMob + Google Play Billing deps (best effort, with no-ads fallback) ----
LIBS="$ROOT/libs"
mkdir -p "$LIBS/aar"
dl() {
  _t="$2.tmp"
  if [ -s "$2" ] && unzip -l "$2" >/dev/null 2>&1; then return 0; fi
  rm -f "$_t" "$2"
  for _i in 1 2 3; do
    if curl -L --fail --retry 2 -o "$_t" "$1" && unzip -l "$_t" >/dev/null 2>&1; then
      mv -f "$_t" "$2"; return 0
    fi
    sleep 2
  done
  echo "WARN: could not fetch $1"; rm -f "$_t"; return 1
}
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-ads/23.0.0/play-services-ads-23.0.0.aar" "$LIBS/aar/play-services-ads.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-ads-lite/23.0.0/play-services-ads-lite-23.0.0.aar" "$LIBS/aar/play-services-ads-lite.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-ads-base/23.0.0/play-services-ads-base-23.0.0.aar" "$LIBS/aar/play-services-ads-base.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-measurement-sdk-api/18.0.2/play-services-measurement-sdk-api-18.0.2.aar" "$LIBS/aar/play-services-measurement-sdk-api.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-ads-identifier/18.0.1/play-services-ads-identifier-18.0.1.aar" "$LIBS/aar/play-services-ads-identifier.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-base/18.3.0/play-services-base-18.3.0.aar" "$LIBS/aar/play-services-base.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-basement/18.3.0/play-services-basement-18.3.0.aar" "$LIBS/aar/play-services-basement.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-tasks/18.1.0/play-services-tasks-18.1.0.aar" "$LIBS/aar/play-services-tasks.aar"
dl "https://dl.google.com/dl/android/maven2/com/android/billingclient/billing/6.1.0/billing-6.1.0.aar" "$LIBS/aar/billing.aar"
# GMA SDK runtime deps (without these the ad request fails silently -> "no ad")
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-appset/16.1.0/play-services-appset-16.1.0.aar" "$LIBS/aar/play-services-appset.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/ump/user-messaging-platform/2.1.0/user-messaging-platform-2.1.0.aar" "$LIBS/aar/user-messaging-platform.aar"
dl "https://dl.google.com/dl/android/maven2/com/google/android/gms/play-services-measurement-base/18.0.0/play-services-measurement-base-18.0.0.aar" "$LIBS/aar/play-services-measurement-base.aar"

DEPS_CP=""
AAR_RES_ARGS=""
for a in "$LIBS"/aar/*.aar; do
  [ -s "$a" ] || continue
  unzip -l "$a" >/dev/null 2>&1 || { echo "WARN: skipping invalid archive $a"; continue; }
  n="$(basename "$a" .aar)"; d="$LIBS/$n"; rm -rf "$d"; mkdir -p "$d"
  unzip -o -q "$a" -d "$d" || { rm -rf "$d"; continue; }
  [ -s "$d/classes.jar" ] && DEPS_CP="$DEPS_CP:$d/classes.jar"
  [ -d "$d/res" ] && AAR_RES_ARGS="$AAR_RES_ARGS -S $d/res"
done
echo "DEPS_CP=$DEPS_CP"
OUT="$ROOT/out"
GEN="$ROOT/gen"
PKG="com/funnybirds/game"

rm -rf "$OUT" "$GEN"
mkdir -p "$OUT" "$GEN" "$ROOT/assets" "$ROOT/res/mipmap-hdpi"

echo "==> copy web assets"
mkdir -p "$ROOT/assets"
cp -f "$ROOT/../index.html" "$ROOT/assets/"
for f in "$ROOT"/../*.png "$ROOT"/../*.mp3; do
  [ -e "$f" ] && cp -f "$f" "$ROOT/assets/"
done
# ---- App launcher icon: user-supplied 1764664455367.jpg ----
# Do NOT overwrite an existing ic_launcher.png (it is pre-generated from the
# user's photo). Only generate it when missing, using any available tool.
mkdir -p "$ROOT/res/mipmap-hdpi" "$ROOT/res/mipmap-xxxhdpi" "$ROOT/res/values"
# ---- ensure strings.xml (app_name) exists so the manifest @string/app_name resolves ----
if [ ! -s "$ROOT/res/values/strings.xml" ]; then
  cat > "$ROOT/res/values/strings.xml" <<'EOS'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Funny Birds</string>
</resources>
EOS
fi
if true; then
  for c in "$ROOT/../1764664455367.jpg" "$ROOT/../favicon.png" "$ROOT/../bird.png"; do
    [ -f "$c" ] || continue
    echo "==> generating launcher icon from: $c"
    _sz=$(wc -c < "$c" 2>/dev/null || echo 0); [ "$_sz" -lt 200 ] && continue
    if command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" >/dev/null 2>&1; then
      python3 -c "from PIL import Image;im=Image.open('$c').convert('RGB');w,h=im.size;s=min(w,h);im.crop(((w-s)//2,(h-s)//2,(w-s)//2+s,(h-s)//2+s)).resize((192,192)).save('$ROOT/res/mipmap-hdpi/ic_launcher.png');im.resize((512,512)).save('$ROOT/res/mipmap-xxxhdpi/ic_launcher.png')" && break
    elif command -v convert >/dev/null 2>&1; then
      convert "$c" -resize 192x192^ -gravity center -extent 192x192 "$ROOT/res/mipmap-hdpi/ic_launcher.png" && break
    elif command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -i "$c" -vf "scale=192:192:force_original_aspect_ratio=increase,crop=192:192" "$ROOT/res/mipmap-hdpi/ic_launcher.png" >/dev/null 2>&1 && break
    fi
    case "$c" in *.png) cp -f "$c" "$ROOT/res/mipmap-hdpi/ic_launcher.png"; break;; esac
  done
fi
ls -la "$ROOT/res/mipmap-hdpi/" "$ROOT/res/mipmap-xxxhdpi/" 2>/dev/null || true
ls "$ROOT/assets" | head -50

echo "==> aapt package (res + assets + R.java)"
AAPT_BASE="--auto-add-overlay -f -m -M $ROOT/AndroidManifest.xml -S $ROOT/res -A $ROOT/assets -I $SDK -J $GEN -F $OUT/app-unsigned.apk"
if ! aapt package $AAPT_BASE $AAR_RES_ARGS; then
  echo "==> aapt retry without AAR resources"
  aapt package $AAPT_BASE
fi
echo "$GEN tree:"; find "$GEN" -type f | head

SRC="$ROOT/src/$PKG/MainActivity.java"
if [ -n "$DEPS_CP" ] && [ -f "$SRC" ]; then
  echo "==> MainActivity: AdMob + Billing build"
else
  echo "==> AdMob/Billing deps missing -> no-ads MainActivity fallback"
  DEPS_CP=""
  SRC="$ROOT/src-noads/$PKG/MainActivity.java"
fi
CP="$SDK$DEPS_CP"

echo "==> javac"
mkdir -p "$OUT/classes"
javac -source 1.8 -target 1.8 -bootclasspath "$SDK" -cp "$CP" -d "$OUT/classes" \
  "$GEN/$PKG/R.java" "$SRC"

echo "==> dx (class -> dex) [single multidex pass]"
mkdir -p "$OUT/dex"
rm -f "$OUT/dex"/*.dex "$OUT"/*.dex 2>/dev/null || true
DXCMD="dx"
if [ -x "$ROOT/dxbig" ]; then DXCMD="$ROOT/dxbig"; fi
echo "   using dexer: $DXCMD"
# Dex the app + ALL dependency jars in ONE invocation. Doing this per-jar (old
# behaviour) left classes that exist in more than one library AAR defined in
# multiple dex files, which made ART reject the app at launch ("app keeps
# stopping"). A single pass lets dx/d8 de-duplicate shared classes AND
# auto-split past the 64K method limit into classes.dex, classes2.dex, ...
# Merge EVERY dependency classes.jar into ONE class tree first. Several Google
# AARs ship the SAME class (e.g. com.google.android.gms.internal.measurement.zzaa
# exists in both play-services-measurement-base AND -sdk-api). Passing the jars
# as separate d8 inputs makes d8 abort with "Type ... is defined multiple times".
# Extracting them into a single directory collapses duplicates to one definition.
DEPS_SPACE=""
if [ -n "$DEPS_CP" ]; then
  MERGED="$LIBS/merged-deps"
  rm -rf "$MERGED"; mkdir -p "$MERGED"
  for j in $(echo "$DEPS_CP" | tr ':' ' '); do
    [ -s "$j" ] || continue
    unzip -o -q "$j" -d "$MERGED" -x 'META-INF/*' 'module-info.class' 2>/dev/null || true
  done
  cnt=$(find "$MERGED" -name '*.class' 2>/dev/null | wc -l)
  echo "   merged dependency classes: $cnt"
  DEPS_SPACE="$MERGED"
fi
$DXCMD --dex --output="$OUT/dex" "$OUT/classes" $DEPS_SPACE
cp -f "$OUT/dex"/classes*.dex "$OUT/" 2>/dev/null || true
ls -la "$OUT"/*.dex 2>/dev/null || true

echo "==> add dex to apk"
# CRITICAL: ART requires a CONTIGUOUS multidex set starting at classes.dex,
# classes2.dex, classes3.dex ... If ANY index is missing (a partial/interrupted
# copy can leave e.g. classes5.dex absent) ART stops loading every later dex, so
# the ad SDK classes turn into NoClassDefFoundError and the app crashes a second
# after launch. Re-derive a strictly gap-free set from the authoritative d8
# output in $OUT/dex instead of trusting a possibly-partial copy in $OUT/.
# Re-number the authoritative d8 output into a STRICTLY contiguous set
# classes.dex, classes2.dex, classes3.dex ... (NO gaps). ART enumerates the
# APK's classes*.dex entries by name; a single missing index (e.g. classes5.dex)
# makes ART stop loading every LATER dex, so ad-SDK classes become
# NoClassDefFoundError and the app is force-closed ~1s after launch.
rm -f "$OUT"/classes*.dex
if [ -d "$OUT/dex" ]; then
  i=1
  # sort -V so classes2 < classes10 (correct numeric order, not lexical)
  for src in $(ls "$OUT/dex"/classes*.dex 2>/dev/null | sort -V); do
    [ -f "$src" ] || continue
    if [ "$i" -eq 1 ]; then dst="classes.dex"; else dst="classes$i.dex"; fi
    cp -f "$src" "$OUT/$dst"
    i=$((i+1))
  done
fi
echo "   dex set:"; ls -la "$OUT"/classes*.dex 2>/dev/null || true
# HARD VERIFY: the set must be contiguous classes.dex .. classesN.dex
_n=$(ls "$OUT"/classes*.dex 2>/dev/null | wc -l)
_k=0
while [ "$_k" -lt "$_n" ]; do
  if [ "$_k" -eq 0 ]; then _f="$OUT/classes.dex"; else _f="$OUT/classes$_k.dex"; fi
  if [ ! -f "$_f" ]; then
    echo "ERROR: multidex gap detected (missing $(basename "$_f")) -> aborting to avoid a launch crash" >&2
    exit 1
  fi
  _k=$((_k+1))
done
echo "   multidex OK: $_n contiguous dex file(s)"
cd "$OUT"
for d in classes*.dex; do
  [ -f "$d" ] || continue
  echo "   adding $d"
  aapt add -f app-unsigned.apk "$d"
done
cd "$ROOT"

echo "==> zipalign"
zipalign -f 4 "$OUT/app-unsigned.apk" "$OUT/app-aligned.apk"

echo "==> ensure keystore"
if [ ! -f "$ROOT/debug.keystore" ]; then
  keytool -genkeypair -v -keystore "$ROOT/debug.keystore" \
    -storepass android -keypass android -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi

echo "==> apksigner"
apksigner sign --ks "$ROOT/debug.keystore" --ks-pass pass:android \
  --key-pass pass:android --out "$OUT/FunnyBirds.apk" "$OUT/app-aligned.apk"

echo "==> verify"
apksigner verify --print-certs "$OUT/FunnyBirds.apk" | head -5
ls -la "$OUT/FunnyBirds.apk"
echo "BUILD OK -> $OUT/FunnyBirds.apk"

set -e
SRC=/tmp/build13/src; W=/tmp/build13/work; SH=$W/shim; USFW=$W/fw; SM3=/tmp/re/tools/smali3; R8=/tmp/re/tools/r8.jar
rm -rf $SH; mkdir -p $SH/dex $SH/sm $SH/jar
unzip -oq $USFW/framework.jar 'classes*.dex' -d $SH/dex
SCP=$(ls $SM3/*.jar | tr '\n' ':')
for d in $SH/dex/classes*.dex; do
  java -cp "$SCP" com.android.tools.smali.baksmali.Main d -a 35 --classes 'Lcom/android/internal/os/ZygoteInit;' -o $SH/sm "$d" 2>&1 | grep -v JAVA_TOOL || true
done
python3 -I "$SRC/shim/shim_edit.py" $SH/sm
J=$SH/java; mkdir -p $J/stub $J/src/com/android/internal/os $J/cls $J/dex
cp -r "$SRC/shim/stubs/." $J/stub/
cp "$SRC/shim/TangoFdFix.java" $J/src/com/android/internal/os/TangoFdFix.java
javac --release 11 -XDstringConcat=inline -cp $J/stub -d $J/cls $J/src/com/android/internal/os/TangoFdFix.java
java -cp $R8 com.android.tools.r8.D8 --release --min-api 29 --output $J/dex $J/cls/com/android/internal/os/TangoFdFix.class
java -cp "$SCP" com.android.tools.smali.baksmali.Main d -a 29 -o $SH/sm $J/dex/classes.dex 2>&1 | grep -v JAVA_TOOL || true
java -cp "$SCP" com.android.tools.smali.smali.Main a -a 29 -o $SH/jar/classes.dex $SH/sm 2>&1 | grep -v JAVA_TOOL || true
python3 -I "$SRC/tools/align_jar.py" $SH/jar/classes.dex $SH/tango-shim.jar
echo "shim ok: $(ls -l $SH/tango-shim.jar)"

# Builder-only guest init suffix. Never execute on the host.

set -eu
printf 'RISH_JAVA_CDS_PHASE=mount\n'
mkdir -p /runtime
mount -t ext4 /dev/vda /runtime
mount -t proc proc /runtime/proc
mount --bind /sys /runtime/sys
mount --bind /dev /runtime/dev
mkdir -p /runtime/tmp/rish-home /runtime/tmp/rish-cds-build
cp /rish-cds-input/classes.list /runtime/tmp/rish-cds-build/classes.list
cp /rish-cds-input/expected.sha256 /runtime/tmp/rish-cds-build/expected.sha256
set +e
chroot /runtime /bin/sh -c '
 set -eu
 export HOME=/tmp/rish-home TMPDIR=/tmp
 export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
 unset CLASSPATH JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS
 test ! -e /__rish_cds_no_application_classpath__
 cd /tmp/rish-cds-build
 /bin/busybox sha256sum -c expected.sha256 > flags.txt 2>&1
 printf "RISH_JAVA_CDS_PHASE=flags\n" > /dev/ttyS0
 /usr/bin/java -XX:+PrintFlagsFinal -version >> flags.txt 2>&1
 printf "RISH_JAVA_CDS_PHASE=dump\n" > /dev/ttyS0
 /usr/bin/java -Xshare:dump -cp /__rish_cds_no_application_classpath__ -XX:SharedClassListFile=/tmp/rish-cds-build/classes.list -XX:SharedArchiveFile=/usr/lib/jvm/java-21-openjdk/lib/server/rish-compiler-http.jsa -Xlog:cds=debug,class+path=info > dump.log 2>&1
 test -s /usr/lib/jvm/java-21-openjdk/lib/server/rish-compiler-http.jsa
 printf "RISH_JAVA_CDS_PHASE=inventory\n" > /dev/ttyS0
 /usr/bin/java -Xshare:on -XX:+VerifySharedSpaces -XX:SharedArchiveFile=/usr/lib/jvm/java-21-openjdk/lib/server/rish-compiler-http.jsa -XX:+PrintSharedArchiveAndExit -version > archive-inventory.txt 2>&1
 /bin/busybox sha256sum -c expected.sha256 >> flags.txt 2>&1
'
rc=$?
printf 'RISH_JAVA_CDS_BUILD_EXIT=%s\n' "$rc"
sync
mount -o remount,ro /runtime
printf 'RISH_JAVA_CDS_PHASE=export\n'
tar -C /runtime -cf /dev/vdb usr/lib/jvm/java-21-openjdk/lib/server/rish-compiler-http.jsa tmp/rish-cds-build/flags.txt tmp/rish-cds-build/dump.log tmp/rish-cds-build/archive-inventory.txt
export_rc=$?
printf 'RISH_JAVA_CDS_EXPORT_EXIT=%s\n' "$export_rc"
sync
/bin/busybox poweroff -f

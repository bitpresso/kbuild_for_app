#!/bin/sh
#
# link app
#

# Error out on error
set -e

# Nice output in kbuild format
# Will be supressed by "make -s"
info()
{
	if [ "${quiet}" != "silent_" ]; then
		printf "  %-7s %s\n" ${1} ${2}
	fi
}

# Link of app
# ${1} - optional extra .o files
# ${2} - output file
app_link()
{
	${CC} ${LDFLAGS} ${LDFLAGS_app} -o ${2} ${KBUILD_APP_MAIN} ${1}
}

# Create ${2} .o file with all symbols from the ${1} object file
kallsyms()
{
	info KSYM ${2}
	local kallsymopt;

	if [ -n "${CONFIG_HAVE_UNDERSCORE_SYMBOL_PREFIX}" ]; then
		kallsymopt="${kallsymopt} --symbol-prefix=_"
	fi

	if [ -n "${CONFIG_KALLSYMS_ALL}" ]; then
		kallsymopt="${kallsymopt} --all-symbols"
	fi

	kallsymopt="${kallsymopt} --page-offset=$CONFIG_PAGE_OFFSET"

	local aflags="${KBUILD_AFLAGS} ${KBUILD_AFLAGS_KERNEL}               \
		      ${NOSTDINC_FLAGS} ${LINUXINCLUDE} ${KBUILD_CPPFLAGS}"

	${NM} -n ${1} | \
		scripts/kallsyms ${kallsymopt} | \
		${CC} ${aflags} -c -o ${2} -x assembler-with-cpp -
}

# Create map file with all symbols from ${1}
# See mksymap for additional details
mksysmap()
{
	${CONFIG_SHELL} "${srctree}/scripts/mksysmap" ${1} ${2}
}

sortextable()
{
	${objtree}/scripts/sortextable ${1}
}

# Delete output files in case of error
trap cleanup SIGHUP SIGINT SIGQUIT SIGTERM ERR
cleanup()
{
	rm -f .old_version
	rm -f .tmp_System.map
	rm -f .tmp_kallsyms*
	rm -f .tmp_version
	rm -f .tmp_app*
	rm -f System.map
	rm -f ${KBUILD_IMAGE}
	rm -f ${KBUILD_IMAGE}.o
}

#
#
# Use "make V=1" to debug this script
case "${KBUILD_VERBOSE}" in
*1*)
	set -x
	;;
esac

if [ "$1" = "clean" ]; then
	cleanup
	exit 0
fi

# We need access to CONFIG_ symbols
case "${KCONFIG_CONFIG}" in
*/*)
	. "${KCONFIG_CONFIG}"
	;;
*)
	# Force using a file from the current directory
	. "./${KCONFIG_CONFIG}"
esac


# Update version
info GEN .version
if [ ! -r .version ]; then
	rm -f .version;
	echo 1 >.version;
else
	mv .version .old_version;
	expr 0$(cat .old_version) + 1 >.version;
fi;

kallsymso=""
kallsyms_app=""
if [ -n "${CONFIG_KALLSYMS}" ]; then

	# kallsyms support
	# Generate section listing all symbols and add it into app
	# It's a three step process:
	# 1)  Link .tmp_app1 so it has all symbols and sections,
	#     but __kallsyms is empty.
	#     Running kallsyms on that gives us .tmp_kallsyms1.o with
	#     the right size
	# 2)  Link .tmp_app2 so it now has a __kallsyms section of
	#     the right size, but due to the added section, some
	#     addresses have shifted.
	#     From here, we generate a correct .tmp_kallsyms2.o
	# 2a) We may use an extra pass as this has been necessary to
	#     woraround some alignment related bugs.
	#     KALLSYMS_EXTRA_PASS=1 is used to trigger this.
	# 3)  The correct ${kallsymso} is linked into the final app.
	#
	# a)  Verify that the System.map from app matches the map from
	#     ${kallsymso}.

	kallsymso=.tmp_kallsyms2.o
	kallsyms_app=.tmp_app2

	# step 1
	app_link "" .tmp_app1
	kallsyms .tmp_app1 .tmp_kallsyms1.o

	# step 2
	app_link .tmp_kallsyms1.o .tmp_app2
	kallsyms .tmp_app2 .tmp_kallsyms2.o

	# step 2a
	if [ -n "${KALLSYMS_EXTRA_PASS}" ]; then
		kallsymso=.tmp_kallsyms3.o
		kallsyms_app=.tmp_app3

		app_link .tmp_kallsyms2.o .tmp_app3

		kallsyms .tmp_app3 .tmp_kallsyms3.o
	fi
fi

info LD ${KBUILD_IMAGE}
app_link "${kallsymso}" ${KBUILD_IMAGE}

if [ -n "${CONFIG_BUILDTIME_EXTABLE_SORT}" ]; then
	info SORTEX ${KBUILD_IMAGE}
	sortextable ${KBUILD_IMAGE}
fi

info SYSMAP System.map
mksysmap ${KBUILD_IMAGE} System.map

# step a (see comment above)
if [ -n "${CONFIG_KALLSYMS}" ]; then
	mksysmap ${kallsyms_app} .tmp_System.map

	if ! cmp -s System.map .tmp_System.map; then
		echo >&2 Inconsistent kallsyms data
		echo >&2 Try "make KALLSYMS_EXTRA_PASS=1" as a workaround
		cleanup
		exit 1
	fi
fi

# We made a new kernel - delete old version file
rm -f .old_version

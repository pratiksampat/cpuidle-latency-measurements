#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# CPU-Idle latency selftest provides support to systematically extract,
# analyse and present IPI and timer based wakeup latencies for each CPU
# and each idle state available on the system by leveraging the
# test-cpuidle_latency module
#
# Author: Pratik R. Sampat <psampat@linux.ibm.com>

LOG=cpuidle.log
MODULE=./test-cpuidle_latency.ko

# Kselftest framework requirement - SKIP code is 4.
ksft_skip=4

RUN_TIMER_TEST=0
VERBOSE=0

DISABLE=1
ENABLE=0

helpme()
{
	printf "Usage: $0 [-h] [-todg args]
	[-h <help>]
	[-i <run timer tests>]
	[-m <location of the module>]
	[-o <location of the output>]
	[-v <verbose>]
	\n"
	exit 2
}

parse_arguments()
{
	while getopts ht:m:o:vt:it: arg
	do
		case $arg in
			h) # --help
				helpme
				;;
			i) # run timer tests
				RUN_TIMER_TEST=1
				;;
			m) # --mod-file
				MODULE=$OPTARG
				;;
			o) # output log files
				LOG=$OPTARG
				;;
			v) # Verbose mode
				VERBOSE=1
				;;
			\?)
				helpme
				;;
		esac
	done
}

ins_mod()
{
	debugfs_file=/sys/kernel/debug/latency_test/ipi_latency_ns
	# Check if the module is already loaded
	if [ -f "$debugfs_file" ]; then
		printf "Module already loaded\n\n"
		return 0
	fi
	# Try to load the module
	if [ ! -f "$MODULE" ]; then
		printf "$MODULE module does not exist. Exitting\n"
		exit $ksft_skip
	fi
	printf "Inserting $MODULE module\n\n"
	insmod $MODULE
	if [ $? != 0 ]; then
		printf "Insmod $MODULE failed\n"
		exit $ksft_skip
	fi
}

compute_average()
{
	arr=("$@")
	sum=0
	size=${#arr[@]}
	if [ $size == 0 ]; then
		avg=0
		return 1
	fi
	for i in "${arr[@]}"
	do
		sum=$((sum + i))
	done
	avg=$((sum/size))
}

cpu_is_online()
{
	cpu=$1
	if [ ! -f "/sys/devices/system/cpu/cpu$cpu/online" ]; then
		echo 1
		return
	fi
	status=$(cat /sys/devices/system/cpu/cpu$cpu/online)
	echo $status
}

# Perform operation on each CPU for the given state
# $1 - Operation: enable (0) / disable (1)
# $2 - State to enable
op_state()
{
	for ((cpu=0; cpu<NUM_CPUS; cpu++))
	do
		local cpu_status=$(cpu_is_online $cpu)
		if [ $cpu_status == 0 ]; then
			continue
		fi
		echo $1 > /sys/devices/system/cpu/cpu$cpu/cpuidle/state$2/disable
	done
}

cpuidle_enable_state()
{
	state=$1
	op_state $ENABLE $state
}

cpuidle_disable_state()
{
	state=$1
	op_state $DISABLE $state
}

# Enable/Disable all stop states for all CPUs
# $1 - Operation: enable (0) / disable (1)
op_cpuidle()
{
	for ((state=0; state<NUM_STATES; state++))
	do
		op_state $1 $state
	done
}

# Extract latency in microseconds and convert to nanoseconds
extract_latency()
{
	for ((state=0; state<NUM_STATES; state++))
	do
		latency=$(($(cat /sys/devices/system/cpu/cpu0/cpuidle/state$state/latency) * 1000))
		latency_arr+=($latency)
	done
}

# Simple linear search in an array
# $1 - Element to search for
# $2 - Array
element_in()
{
	local item="$1"
	shift
	for element in "$@";
	do
		if [ "$element" == "$item" ]; then
			return 0
		fi
	done
	return 1
}

# Parse and return a cpuset with ","(individual) and "-" (range) of CPUs
# $1 - cpuset string
parse_cpuset()
{
	echo $1 | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} 1' RS=, FS=-
}

extract_core_information()
{
	declare -a thread_arr
	for ((cpu=0; cpu<NUM_CPUS; cpu++))
	do
		local cpu_status=$(cpu_is_online $cpu)
		if [ $cpu_status == 0 ]; then
			continue
		fi

		siblings=$(cat /sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list)
		sib_arr=()
		for c in $(parse_cpuset $siblings)
		do
			sib_arr+=($c)
		done

		if [ $VERBOSE == 1 ]; then
			core_arr+=($cpu)
			for thread in "${sib_arr[@]}"
			do
				if [ $cpu == 0 ]; then
					first_core_arr+=($thread)
				fi
			done
			continue
		fi

		element_in "${sib_arr[0]}" "${thread_arr[@]}"
		if [ $? == 0 ]; then
			continue
		fi
		core_arr+=(${sib_arr[0]})

		for thread in "${sib_arr[@]}"
		do
			thread_arr+=($thread)
			if [ $cpu == 0 ]; then
				first_core_arr+=($thread)
			fi
		done
	done
}

# Run the IPI test
# $1 run for baseline - busy cpu or regular environment
# $2 destination cpu
ipi_test_once()
{
	dest_cpu=$2
	if [ "$1" = "baseline" ]; then
		# Keep the CPU busy
		taskset -c $dest_cpu cat /dev/random > /dev/null &
		task_pid=$!
		# Wait for the workload to achieve 100% CPU usage
		sleep 1
	fi
	taskset 0x1 echo $dest_cpu > /sys/kernel/debug/latency_test/ipi_cpu_dest
	ipi_latency=$(cat /sys/kernel/debug/latency_test/ipi_latency_ns)
	src_cpu=$(cat /sys/kernel/debug/latency_test/ipi_cpu_src)
	if [ "$1" = "baseline" ]; then
		kill $task_pid
		wait $task_pid 2>/dev/null
	fi
}

# Incrementally Enable idle states one by one and compute the latency
run_ipi_tests()
{
	extract_latency
	# Disable idle states for CPUs
	op_cpuidle $DISABLE

	declare -a avg_arr
	echo -e "--IPI Latency Test---" | tee -a $LOG

	echo -e "--Baseline IPI Latency measurement: CPU Busy--" >> $LOG
	printf "%s %10s %12s\n" "SRC_CPU" "DEST_CPU" "IPI_Latency(ns)" >> $LOG
	for cpu in "${core_arr[@]}"
	do
		local cpu_status=$(cpu_is_online $cpu)
		if [ $cpu_status == 0 ]; then
			continue
		fi
		ipi_test_once "baseline" $cpu
		printf "%-3s %10s %12s\n" $src_cpu $cpu $ipi_latency >> $LOG
		# Skip computing latency average from the source CPU to avoid bias
		element_in "$cpu" "${first_core_arr[@]}"
		if [ $? == 0 ]; then
			continue
		fi
		avg_arr+=($ipi_latency)
	done
	compute_average "${avg_arr[@]}"
	echo -e "Baseline Avg IPI latency(ns): $avg" | tee -a $LOG

	for ((state=0; state<NUM_STATES; state++))
	do
		unset avg_arr
		echo -e "---Enabling state: $state---" >> $LOG
		cpuidle_enable_state $state
		printf "%s %10s %12s\n" "SRC_CPU" "DEST_CPU" "IPI_Latency(ns)" >> $LOG
		for cpu in "${core_arr[@]}"
		do
			local cpu_status=$(cpu_is_online $cpu)
			if [ $cpu_status == 0 ]; then
				continue
			fi
			# Running IPI test and logging results
			sleep 1
			ipi_test_once "test" $cpu
			printf "%-3s %10s %12s\n" $src_cpu $cpu $ipi_latency >> $LOG
			# Skip computing latency average from the source CPU to avoid bias
			element_in "$cpu" "${first_core_arr[@]}"
			if [ $? == 0 ]; then
				continue
			fi
			avg_arr+=($ipi_latency)
		done
		compute_average "${avg_arr[@]}"
		echo -e "Expected IPI latency(ns): ${latency_arr[$state]}" >> $LOG
		echo -e "Observed Avg IPI latency(ns) - State $state: $avg" | tee -a $LOG
		cpuidle_disable_state $state
	done
}

# Extract the residency in microseconds and convert to nanoseconds.
# Add 200 ns so that the timer stays for a little longer than the residency
extract_residency()
{
	for ((state=0; state<NUM_STATES; state++))
	do
		residency=$(($(cat /sys/devices/system/cpu/cpu0/cpuidle/state$state/residency) * 1000 + 200))
		residency_arr+=($residency)
	done
}

# Run the Timeout test
# $1 run for baseline - busy cpu or regular environment
# $2 destination cpu
# $3 timeout
timeout_test_once()
{
	dest_cpu=$2
	if [ "$1" = "baseline" ]; then
		# Keep the CPU busy
		taskset -c $dest_cpu cat /dev/random > /dev/null &
		task_pid=$!
		# Wait for the workload to achieve 100% CPU usage
		sleep 1
	fi
	taskset -c $dest_cpu echo $3 > /sys/kernel/debug/latency_test/timeout_expected_ns
	# Wait for the result to populate
	sleep 0.1
	timeout_diff=$(cat /sys/kernel/debug/latency_test/timeout_diff_ns)
	src_cpu=$(cat /sys/kernel/debug/latency_test/timeout_cpu_src)
	if [ "$1" = "baseline" ]; then
		kill $task_pid
		wait $task_pid 2>/dev/null
	fi
}

run_timeout_tests()
{
	extract_residency
	# Disable idle states for all CPUs
	op_cpuidle $DISABLE

	declare -a avg_arr
	echo -e "\n--Timeout Latency Test--" | tee -a $LOG

	echo -e "--Baseline Timeout Latency measurement: CPU Busy--" >> $LOG
	printf "%s %10s %10s\n" "Wakeup_src" "Baseline_delay(ns)">> $LOG
	for cpu in "${core_arr[@]}"
	do
		local cpu_status=$(cpu_is_online $cpu)
		if [ $cpu_status == 0 ]; then
			continue
		fi
		timeout_test_once "baseline" $cpu 1000000
		printf "%-3s %13s\n" $src_cpu $timeout_diff >> $LOG
		avg_arr+=($timeout_diff)
	done
	compute_average "${avg_arr[@]}"
	echo -e "Baseline Avg timeout diff(ns): $avg" | tee -a $LOG

	for ((state=0; state<NUM_STATES; state++))
	do
		unset avg_arr
		echo -e "---Enabling state: $state---" >> $LOG
		cpuidle_enable_state $state
		printf "%s %10s %10s\n" "Wakeup_src" "Baseline_delay(ns)" "Delay(ns)" >> $LOG
		for cpu in "${core_arr[@]}"
		do
			local cpu_status=$(cpu_is_online $cpu)
			if [ $cpu_status == 0 ]; then
				continue
			fi
			timeout_test_once "test" $cpu 1000000
			printf "%-3s %13s %18s\n" $src_cpu $baseline_timeout_diff $timeout_diff >> $LOG
			avg_arr+=($timeout_diff)
		done
		compute_average "${avg_arr[@]}"
		echo -e "Expected timeout(ns): ${residency_arr[$state]}" >> $LOG
		echo -e "Observed Avg timeout diff(ns) - State $state: $avg" | tee -a $LOG
		cpuidle_disable_state $state
	done
}

declare -a residency_arr
declare -a latency_arr
declare -a core_arr
declare -a first_core_arr

parse_arguments $@

rm -f $LOG
touch $LOG
NUM_CPUS=$(nproc --all)
NUM_STATES=$(ls -1 /sys/devices/system/cpu/cpu0/cpuidle/ | wc -l)

extract_core_information

ins_mod $MODULE

run_ipi_tests
if [ $RUN_TIMER_TEST == 1 ]; then
	run_timeout_tests
fi

# Enable all idle states for all CPUs
op_cpuidle $ENABLE
printf "Removing $MODULE module\n"
printf "Full Output logged at: $LOG\n"
rmmod $MODULE

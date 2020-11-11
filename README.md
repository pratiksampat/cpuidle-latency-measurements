# CPU-Idle latency measurements

A kernel module + userspace driver to estimate the wakeup latency caused
by going into stop states. The motivation behind this program is to find significant deviations
behind advertised latency and residency values

The program measures latencies for two kinds of events. IPIs and Timers. As this is a software-only mechanism, there will additional latency for the kernel-firmware-hardware interactions. To account for that, the program measures a baseline latency on a 100 percent loaded CPU and the latecies achived must be in view of that.


To achieve this, we introduce a kernel module and expose its control
knobs through the debugfs interface that the selftests can engage with.

The kernel module provides the following interfaces within
`/sys/kernel/debug/latency_test/` for,
1. IPI test:\
  `ipi_cpu_dest` = Destination CPU for the IPI\
  `ipi_cpu_src` = Origin of the IPI\
  `ipi_latency_ns` = Measured latency time in ns
2. Timeout test:\
  `timeout_cpu_src`     = CPU on which the timer to be queued\
  `timeout_expected_ns` = Timer duration\
  `timeout_diff_ns`     = Difference of actual duration vs expected timer

The selftest inserts the module, disables all the idle states and
enables them one by one testing the following:
1. Keeping source CPU constant, iterates through all the CPUS measuring
   IPI latency for baseline (CPU is busy with
   `cat /dev/random > /dev/null` workload) and the when the CPU is
   allowed to be at rest
2. Iterating through all the CPUs, sending expected timer durations to
   be equivalent to the residency of the the deepest idle state
   enabled and extracting the difference in time between the time of
   wakeup and the expected timer duration


## Compiling

Compile the kernel module by hitting `make`. Confirm the presence of the module files, especially `test-cpuidle_latency.ko`

## Running

Once the kernel module is compiled, it must be be inserted and run though the `./cpuidle.sh` driver program.

The `cpuidle.sh` accepts the following parameters
```
[-m <location of the module>]
[-o <location of the output>]
[-v <verbose>]
```

By default the program collects latencies only for the first thread of each CPU, if all the threads are needed run with `-v` (verbose) option.

The framework has been tested for IBM POWER9 systems.

## Things to keep in mind

1. This kernel module + bash driver does not guarantee idleness on a core when the IPI and the Timer is armed. It only invokes sleep and hopes that the core is idle once the IPI/Timer is invoked onto it. Hence this program must be run on a completely idle system for best results
2. Even on a completely idle system, there maybe book-keeping tasks or jitter tasks that can run on the core we want idle. This can create outliers in the latency measurement. Thankfully, these outliers should be large enough to easily weed them out.
3. For Intel Systems, the Timer based latencies don't exactly give out the measure of idle latencies. This is because of a hardware optimization mechanism that pre-arms a CPU when a timer is set to wakeup. That doesn't make this metric useless for Intel systems, it just means that is measuring something else rather then idle wakeup latencies. (Source: https://lkml.org/lkml/2020/9/2/610)
    - For solution to this problem, a hardware based latency analyzer is devised by Artem Bityutskiy from Intel. https://youtu.be/Opk92aQyvt0?t=8266\
    https://intel.github.io/wult/

## Attributions

1. srivatsa.bhat@linux.vnet.ibm.com: Initial implementation in cpuidle/sysfs
2. svaidy@linux.vnet.ibm.com: Initial implementation and review of the current implementation
3. ego@linux.vnet.ibm.com: Review and suggestions in the current implementation
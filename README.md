# ushift

CLI tool to manage CPU performance scaling and power profiles

## Install

- GH [releases](https://github.com/doums/ushift/releases/latest)
- AUR https://aur.archlinux.org/packages/ushift

## Quick start

> [!IMPORTANT]
> Changing **scaling governor** or **P-state operation mode**
> requires good understanding of how CPU driver scaling works on
> your system -> _DYOR_\
> In most cases keep kernel defaults.

> [!TIP]
> `ushift -h`

Read current CPU scaling settings

```sh
# print help
ushift get -h

ushift get -g  # scaling governor
ushift get -e  # energy performance policy
ushift get -t  # turbo boost status
```

Set CPU scaling properties - **root required**

```sh
# print help
ushift set -h

# set the Energy Performance Policy (aka EPP/EPB)
sudo ushift set -e balance_performance
sudo ushift set -t yes  # enable turbo boost
sudo ushift set -d yes  # enable HWP dynamic boost (Intel only)
```

Get/set GPU scaling properties

```sh
# on Intel gpus with Xe driver
ushift get -x
sudo ushift set -x power_saving

# on AMD gpus
ushift get -r
sudo ushift set -r low
```

Apply a profile as defined in the config file (see below) - **root required**

```sh
sudo ushift perf  # performance
sudo ushift bal   # balance
sudo ushift sav   # save (low power)
```

## Config file

Default: `/etc/ushift/config.toml`

```toml
## Battery device name to be used in /sys/class/power_supply/
## Only needed if multiple batteries are present, otherwise it is
## detected automatically
# battery_name = "BAT0"
## Battery polling interval in seconds
# battery_poll_rate = 30
## Battery % at which 'save' profile activates
# battery_low = 20

# See `ushift set -h` to get more information about the available
# options

[performance]
## If you understand the implications, you can override the kernel
## defaults for scaling governor and P-state operation mode
# governor = "powersave"
# pstate_op_mode  = "active"
## Energy Performance Policy, possible values: performance,
## balance_performance, default, balance_power, power
energy_perf_policy = "balance_performance"
## Turbo boost
turbo_boost = true
## Intel HWP dynamic boost
# hwp_dyn_boost = true
## Intel gpus with Xe driver, possible values: base, power_saving
# intel_xe_power_profile = "base"
## AMD gpus DPM performance level, possible values:
## auto, low, high
# radeon_dpm_perf_level = "auto"

[balance]
energy_perf_policy = "balance_power"
turbo_boost = true
# hwp_dyn_boost = true
# intel_xe_power_profile = "base"
# radeon_dpm_perf_level = "auto"

# optional - if omitted, the 'save' profile is disabled
[save]
energy_perf_policy = "power"
turbo_boost = false
# hwp_dyn_boost = false
# intel_xe_power_profile = "power_saving"
# radeon_dpm_perf_level = "low"
```

> [!TIP]
> Use `-c <FILE>` to specify a custom config file

Print the parsed config

```sh
ushift cfg
```

## Laptop mode

In _laptop mode_ ushift runs as a daemon and automatically
switches profiles based on power state:

- **performance** - on AC power
- **balance** - on battery
- **save** - on battery below `battery_low` % (only if `save` is defined in config)

> [!NOTE]
> CLI flags override equivalent config file properties.

> [!NOTE]
> ushift uses libudev to detect AC power changes, so battery
> info doesn't need frequent polling. Default rate is 30 seconds
> (`--poll-rate`) so CPU footprint is minimal.

```sh
sudo ushift laptop
```

> [!IMPORTANT]
> Settings do not survive reboot. Use the systemd services below.

## Systemd services

Two services are provided.

**`ushift-laptop.service`** - laptop daemon, switches profiles
automatically:

```sh
sudo systemctl enable --now ushift-laptop.service
```

**`ushift-perf.service`** - oneshot, applies the performance
profile at boot (desktop/server):

```sh
sudo systemctl enable --now ushift-perf.service
```

To use a custom config file,
[override](https://wiki.archlinux.org/title/Systemd#Editing_provided_units)
the service:

```
ExecStart=/usr/bin/ushift laptop --config /path/to/config.toml
```

## Example use cases

#### Laptop with auto-switch profiles, power saving below 15% battery

Enable/start `ushift-laptop.service` with config:

```toml
battery_low = 15 # %

# on AC
[performance]
energy_perf_policy = "balance_performance"
turbo_boost = true
hwp_dyn_boost = true # Intel only

# on battery
[balance]
energy_perf_policy = "balance_power"
turbo_boost = true
hwp_dyn_boost = false

# on battery powersave mode
[save]
energy_perf_policy = "power"
turbo_boost = false
hwp_dyn_boost = false
```

#### Desktop/server perf profile applied at boot

Enable/start `ushift-perf.service` with config:

```toml
[performance]
energy_perf_policy = "balance_performance"
turbo_boost = true
hwp_dyn_boost = true # Intel only
```

#### Oneshot tweak/profile switch

```sh
sudo ushift set -e power  # set Energy Performance Policy to 'power'
sudo ushift sav  # switch to (power)save profile
```

## Implementation details

ushift is a lightweight wrapper around sysfs: reads and writes the
kernel's `cpufreq`/`intel_pstate`/`amd_pstate`/DRM files directly.
No background process except in `laptop` mode.

Laptop mode detects AC changes via `libudev` netlink uevents combined
with `ppoll`, blocking efficiently instead of busy-polling. Battery
level is only checked on a timer when a `save` profile is configured.

## References

- https://docs.kernel.org/admin-guide/pm/cpufreq.html
- https://docs.kernel.org/admin-guide/pm/intel_pstate.html
- https://docs.kernel.org/admin-guide/pm/amd-pstate.html
- https://docs.kernel.org/gpu/xe/index.html
- https://docs.kernel.org/gpu/amdgpu/thermal.html
- https://wiki.archlinux.org/title/CPU_frequency_scaling
- https://github.com/linrunner/TLP

## License

Apache License 2.0 WITH Commons-Clause-1.0

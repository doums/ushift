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

Apply a profile as defined in the config file (see below) - **root required**

```sh
sudo ushift perf  # performance
sudo ushift bal   # balance
sudo ushift sav   # save (low power)
```

## Config file

Default: `/etc/ushift/config.toml`

```toml
# battery device name to be used in /sys/class/power_supply/
# (only needed if multiple batteries are present)
# bat_name = "BAT0"
# bat_poll_rate = 30   # battery polling interval in seconds
# low_level = 20       # battery % at which 'save' profile activates

[performance]
# governor = "powersave"  # scaling governor
# pstate_op_mode  = "active"  # P-state driver operation mode
energy_perf_policy = "balance_performance"
turbo_boost = true
hwp_dyn_boost = true  # Intel only
# xe_power_profile = "base"  # Intel Xe gpu only, base or power_saving

[balance]
energy_perf_policy = "balance_power"
turbo_boost = true
hwp_dyn_boost = true

# optional - if omitted, the 'save' profile is disabled
[save]
energy_perf_policy = "power"
turbo_boost = false
hwp_dyn_boost = false
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
- **save** - on battery below `low_level` % (only if `[save]` is defined in config)

> [!NOTE]
> CLI flags take precedence over config file properties.

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

#### Laptop with auto-switch profiles, power saving below 30% battery

Enable/start `ushift-laptop.service` with config:

```toml
low_level = 30 # %

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

# on battery below 30%
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

#### Oneshot profile switch/tweak

```sh
sudo ushift sav  # switch to (power)save profile
sudo ushift set -t yes  # enable turbo boost
```

---

## References

- https://docs.kernel.org/admin-guide/pm/cpufreq.html
- https://docs.kernel.org/admin-guide/pm/intel_pstate.html
- https://docs.kernel.org/admin-guide/pm/amd-pstate.html
- https://wiki.archlinux.org/title/CPU_frequency_scaling
- https://github.com/linrunner/TLP

## License

Apache License 2.0 WITH Commons-Clause-1.0

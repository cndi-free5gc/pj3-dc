# Dual Connection

The Dual Connection in this project means the ue will establishment **TWO PDU Sessions** for data plane.

All of the code are copy from [free-ran-ue](https://github.com/free-ran-ue).

## Make Command

| Command | Description |
| - | - |
| `make` | build the `pj3/free-ran-ue:latest` image for using |
| `up` | up the DC compose |
| `upd` | up the DC compose in the background |
| `down` | down the DC compose |
| `ue` | enter the ue container |
| `upf` | enter the upf container |
| `build` | free-ran-ue code build check |
| `test` | free-ran-ue code test check |
| `lint` | free-ran-ue code lint check |

## What you need TODO?

1. Complete the task about implementing the requirement of two pdu establishment on single RAN.
2. Put the second PDU session to the secondary RAN.

> [!IMPORTANT]
> **Limitation**: You can only modify the files under free-ran-ue directory.

> [!NOTE]
> **Hint**
> 1. You may need to update the model since there is something additional in both gnb and ue configuration files.
> 2. The second PDU session is required, so the second PDU_SESSION_ID is needed.
> 3. In single-RAN mode, the UE uses the same IP but a different PORT for the two PDU sessions. In dual-RAN (DC) mode, the second PDU session instead talks to the secondary RAN's own IP, which is a different IP but the same PORT as the master's first PDU session.
> 4. The final code should support both single RAN mode and dual RAN mode under two PDU sessions. The config settings are at [gnbcfg-dc-master.yaml](./config/gnbcfg-dc-master.yaml)'s `staticNrdc` and [uecfg-dc.yaml](./config/uecfg-dc.yaml)'s `nrdc.enable`.

## Test

Get into the test directory and run the [grade.sh](test/grade.sh) script.

It is ecpected to see the result as below:

```bash
┌──────────────────────────────────┬───────┬─────────┐
│ Item                             │ Score │ Status  │
├──────────────────────────────────┼───────┼─────────┤
│ Code (build/test/lint)           │ 0/0   │ ✅ PASS │
│ PDU sessions on master RAN       │ 60/60 │ ✅ PASS │
│ PDU session 2 on second RAN (DC) │ 20/20 │ ✅ PASS │
├──────────────────────────────────┼───────┼─────────┤
│ Total                            │ 80/80 │ -       │
└──────────────────────────────────┴───────┴─────────┘
```

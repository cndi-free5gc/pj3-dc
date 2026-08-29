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

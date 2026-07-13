# Firmware role selection (SS-TWR)

The starter firmware runs ONE example, chosen by a matching pair of edits.
For Phase 1 first-light we use single-sided two-way ranging (SS-TWR):
one board INITIATOR, one board RESPONDER.

To switch role, edit BOTH files, then `make build`:

## INITIATOR
- `Src/example_selection.h`: `#define TEST_SS_TWR_INITIATOR` uncommented,
  `TEST_READING_DEV_ID` commented.
- `Src/main.c` (~line 92 dispatch block): `ss_twr_initiator();` line uncommented,
  `read_dev_id();` line commented.

## RESPONDER
- `Src/example_selection.h`: `#define TEST_SS_TWR_RESPONDER` uncommented,
  everything else in the block commented.
- `Src/main.c`: `ss_twr_responder();` line uncommented, all other example
  calls commented.

## Build output
`Output/Common/Exe/dw3000_api.hex` (single artifact per build — rebuild per role).

## Flashing (from macOS host — Docker `make flash` can't pass USB through)
```bash
cat > /tmp/flash.jlink <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
loadfile <abs-path>/Output/Common/Exe/dw3000_api.hex
r
g
exit
EOF
JLinkExe -CommanderScript /tmp/flash.jlink -AutoConnect 1 -ExitOnError 1
```

## Ranging source
The initiator's SS-TWR example computes and logs the distance; the responder
just answers. Distance appears in the initiator's RTT debug log.

Board J-Link serials: #1 = 760224825 (initiator), #2 = 760224846 (responder).

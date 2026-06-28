#!/bin/sh
# (Re)applies custom ebusd message definitions that are NOT part of the official
# Vaillant config, and re-applies them whenever ebusd restarts.
#
# Why this exists: runtime `ebusctl define`s do not survive an ebusd restart, and
# ebusd here runs with the remote --scanconfig, so custom messages cannot be
# shipped as CSV files. Requires EBUSD_ENABLEDEFINE on the ebusd service.
#
# This does NOT poll the bus for data - ebusd does that itself via the poll
# priorities set below (`read -p N`, lower = more frequent). The loop is only a
# watchdog: every CHECK_INTERVAL seconds it checks whether the definitions still
# exist (cheap) and recreates them if ebusd was restarted.

# EBUSD_HOST, EBUSD_PORT and CHECK_INTERVAL are passed via the compose environment.
SENTINEL="Z1RoomHumidity"   # if this message is gone, ebusd was restarted

ec() { ebusctl -s "$EBUSD_HOST" -p "$EBUSD_PORT" "$@"; }

apply_defs() {
  echo "ebusd-define: (re)applying custom messages"

  # --- Per-zone room humidity from the ctlv2 controller -----------------------
  # The VR_92 wall panel (addr 35) has no official ebusd config; the controller
  # exposes per-zone humidity via b524 020003<zone>2800 (zone 00=Z1, 01=Z2).
  ec define -r 'r,ctlv2,Z1RoomHumidity,room humidity zone 1,,15,b524,020003002800,ign,,IGN:4,,,,humidity,,EXP,,%,Raumluftfeuchte Zone 1'
  ec define -r 'r,ctlv2,Z2RoomHumidity,room humidity zone 2,,15,b524,020003012800,ign,,IGN:4,,,,humidity,,EXP,,%,Raumluftfeuchte Zone 2'

  # --- Live gas energy read straight from the boiler (addr 08) via b516 --------
  # The boiler's PrEnergy* (b509) return empty on HW=7603; the controller polls
  # the boiler over b516 instead. Payload 1000ffff<src><use>0000: src 04=gas,
  # use 03=heating 04=hot-water 00=all; reply = Wh (EXP), /1000 -> kWh.
  # Names must contain a mqtt-hassio filter keyword ("energy") to be published.
  ec define -r 'r,bai,GasEnergyHc,gas energy heating total,,08,b516,1000ffff04030000,ign,,IGN:7,,,,value,,EXP,1000,kWh,Gasverbrauch Heizung gesamt'
  ec define -r 'r,bai,GasEnergyHwc,gas energy hot water total,,08,b516,1000ffff04040000,ign,,IGN:7,,,,value,,EXP,1000,kWh,Gasverbrauch Warmwasser gesamt'
  ec define -r 'r,bai,GasEnergyTotal,gas energy total,,08,b516,1000ffff04000000,ign,,IGN:7,,,,value,,EXP,1000,kWh,Gasverbrauch gesamt'

  # --- Make ebusd poll & publish them -----------------------------------------
  ec read -p 3 -f Z1RoomHumidity   >/dev/null 2>&1
  ec read -p 3 -f Z2RoomHumidity   >/dev/null 2>&1
  ec read -p 2 -f GasEnergyHc      >/dev/null 2>&1
  ec read -p 2 -f GasEnergyHwc     >/dev/null 2>&1
  ec read -p 2 -f GasEnergyTotal   >/dev/null 2>&1
}

while true; do
  if ! ec find -f "$SENTINEL" 2>&1 | grep -q "$SENTINEL"; then
    until ec info 2>/dev/null | grep -q 'signal: acquired'; do sleep 3; done
    apply_defs
  fi
  sleep "$CHECK_INTERVAL"
done

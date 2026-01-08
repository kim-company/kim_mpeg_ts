# MPEG.TS
![Hex.pm Version](https://img.shields.io/hexpm/v/mpeg_ts?link=https%3A%2F%2Fhex.pm%2Fpackages%2Fmpeg_ts)


MPEG Transport Stream (TS) library.

This library is the base of our [MPEG.TS plugin for the Membrane
Framework](https://github.com/kim-company/membrane_mpeg_ts_plugin) which is
being battle-tested with production workloads. Checkout its code and the tests
for some usage examples.

Initial table/packet parsing code was copied verbatim from
https://github.com/membraneframework/membrane_mpegts_plugin.

## Private PES (JSON) example

Use `:PES_PRIVATE_DATA` with a registration descriptor (tag `0x05`) to signal
custom payloads such as JSON:

```elixir
alias MPEG.TS.Muxer

descriptors = [%{tag: 0x05, data: "JSON"}]
{pid, muxer} = Muxer.add_elementary_stream(Muxer.new(), :PES_PRIVATE_DATA, descriptors: descriptors)
{pat, muxer} = Muxer.mux_pat(muxer)
{pmt, muxer} = Muxer.mux_pmt(muxer)

json_payload = ~s({"type":"json","value":1})
{packets, _muxer} = Muxer.mux_sample(muxer, pid, json_payload, 0, sync?: true)
```

## Copyright and License
Copyright 2022, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](LICENSE)

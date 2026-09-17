# Waveform Rendering Specification

## Purpose

`peak` renders audio waveforms as PNG images. This spec pins the output format (400x200 PNG-only), the IDAT compression route (`std.compress.flate`), and the dead-code removals that keep the writer honest.

## Requirements

### Requirement: Fixed 400x200 PNG canvas

The system MUST render the waveform as a single PNG image of exactly 400x200 pixels. The source comment describing the canvas SHALL state 400x200.

#### Scenario: Nominal render

- GIVEN a decoded audio file with at least one frame
- WHEN `peak` renders the PNG
- THEN the PNG width field is 400
- AND the height field is 200

#### Scenario: Comment accuracy

- GIVEN the source of the PNG writer
- WHEN searching for the canvas-size comment
- THEN it states 400x200

### Requirement: PNG-only output

The system MUST emit PNG as its only image output. The system MUST NOT emit Kitty Graphics images and MUST NOT accept a `--png` flag.

#### Scenario: Default invocation emits PNG

- GIVEN `peak` invoked with an audio path
- WHEN output is produced
- THEN it is a PNG file

#### Scenario: Kitty path absent

- GIVEN the source tree after the change
- WHEN searching for Kitty render code or the `--png` flag
- THEN neither exists

### Requirement: flate-compressed IDAT

The IDAT chunk MUST be compressed with `std.compress.flate`. The hand-rolled stored-block zlib writer MUST NOT remain.

#### Scenario: IDAT uses flate

- GIVEN a rendered PNG
- WHEN its IDAT chunk is inspected
- THEN it carries DEFLATE-compressed data produced by `std.compress.flate`

### Requirement: flate round-trip integrity

The compressed raster MUST round-trip: flate-encode then flate-decode MUST yield the identical sample stream. This mitigates `std.compress.flate` API drift across Zig dev builds.

#### Scenario: Representative round-trip

- GIVEN a representative bucket sample set
- WHEN encoded with `std.compress.flate` and decoded back
- THEN decoded samples equal the originals exactly

#### Scenario: Minimal input round-trip

- GIVEN a minimal non-empty sample set
- WHEN round-tripped
- THEN samples are unchanged

### Requirement: crc32 removal

The system MUST NOT define a `crc32` wrapper function. `crc32Update` SHALL remain, as `writePngChunk` uses it directly.

#### Scenario: Function absence and presence

- GIVEN the source tree after the change
- WHEN searching for PNG CRC functions
- THEN `crc32Update` is present and `crc32` is absent

### Requirement: amplitude bucketing seam

The system SHALL decompose frames into exactly 400 amplitude buckets via a pure, testable function, matching the 400px canvas width, so `zig build test` covers bucketing without IO.

#### Scenario: Synthetic frames

- GIVEN frames with known peak amplitudes
- WHEN the bucketing function runs
- THEN it returns 400 buckets whose per-bucket peaks match the input

#### Scenario: Multi-channel frames

- GIVEN multi-channel frames
- WHEN the bucketing function runs
- THEN all channels contribute and the bucket count stays 400
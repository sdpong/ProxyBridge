// ppx.h - read a Proxifier profile (.ppx) into a ProxyBridge profile.
//
// A .ppx is an XML document. Proxifier for macOS and Proxifier for Windows write the
// same format, so one reader serves both. The macOS side has the same mapping in
// MacOS/ProxyBridge/ProxyBridge/PPXImporter.swift; the two have to agree, so the test
// files hold the same cases.
#ifndef PB_PPX_H
#define PB_PPX_H

#include "profile.h"

// Reads a Proxifier profile and fills the profile structure with it.
//   path    - the file to read
//   p       - the profile to fill (its defaults are set first)
//   notes   - what could not be carried over, one line per item; may be NULL
//   cchNotes- the size of the notes buffer
// Returns TRUE when the file was read. A file that is not a Proxifier profile is
// refused, and nothing is written into the profile in that case.
BOOL PB_ImportPPX(const wchar_t* path, PBProfile* p, wchar_t* notes, int cchNotes);

// The same, for a profile that is already in memory. Used by the tests.
BOOL PB_ImportPPXData(const char* data, size_t len, PBProfile* p, wchar_t* notes, int cchNotes);

#endif // PB_PPX_H

#pragma once
#include <string>

// Borrows an already-owned descriptor; never reads packets or changes its flags.
std::string InspectVpnDescriptor(int fd);

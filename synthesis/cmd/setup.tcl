# ============================================================
# DeepCABAC - Cadence Genus Technology Setup
# Technology: Nangate45
# Timing corner: Typical
# ============================================================

# Standard-cell library
set_db init_lib_search_path ../Technology/Nangate45/lib/
set_db library NangateOpenCellLibrary_typical.lib

# RTL source directory
set_db init_hdl_search_path ../

# Synthesis scripts
set_db script_search_path ./cmd/

# VHDL configuration
set_db hdl_vhdl_read_version 2008
set_db hdl_enable_real_support true

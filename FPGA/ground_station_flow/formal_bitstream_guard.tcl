# Both GUI Generate Bitstream and batch runs stop before official DRC masking.
# The original official pre/post hooks remain preserved, byte for byte.
# This gate must be replaced by a reviewed source-bound signoff after the actual
# clock/DRC/reset/I/O blockers are resolved; a local flag is not a waiver.
error "Formal board is not cleared for bitstream: retained AI_Mate clock minimum-period failures, unresolved platform DRC/CDC/I/O contracts. See the formal project README. No vendor bitstream patch executed."

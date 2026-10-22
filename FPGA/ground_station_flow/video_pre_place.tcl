set video_audit_stage [file dirname [info script]]
source [file join $video_audit_stage video_platform_pin_audit.tcl]
video_platform_pin_audit platform_pins_before_place.txt
source [file join $video_audit_stage multinode_control_merge.tcl]

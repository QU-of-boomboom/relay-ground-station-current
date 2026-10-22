# Standalone Tcl 8.5 process. Exactly one operation; no retry or persistent state.
namespace eval ::formal_file_process {variable maximum_bytes 4194304}
proc ::formal_file_process::read_binary {path} {
 variable maximum_bytes
 if {![file isfile $path]} {error "Formal input is not a regular file: $path"}
 set before [file size $path]
 if {$before < 1 || $before > $maximum_bytes} {error "Formal input size rejected: $before bytes"}
 set fd ""
 set code [catch {
  set fd [open $path r]
  fconfigure $fd -encoding binary -translation binary -blocking 1
  set bytes [read $fd [expr {$maximum_bytes+1}]]
  set ended [eof $fd]
  set after [file size $path]
  set length [string length $bytes]
  if {!$ended || $length != $before || $length != $after || $length > $maximum_bytes} {
   error "Formal input byte/size mismatch: before=$before read=$length after=$after eof=$ended"
  }
  set bytes
 } result options]
 set close_code 0
 if {$fd ne ""} {set close_code [catch {close $fd} close_result close_options]}
 if {$code} {
  if {$close_code} {dict append options -errorinfo "\nAdditional owned input close error: $close_result"}
  return -options $options $result
 }
 if {$close_code} {return -options $close_options $close_result}
 return $result
}
proc ::formal_file_process::write_binary_new {path bytes} {
 variable maximum_bytes
 set length [string length $bytes]
 if {$length < 1 || $length > $maximum_bytes} {error "Formal output size rejected: $length bytes"}
 set fd ""
 set code [catch {
  set fd [open $path {WRONLY CREAT EXCL}]
  fconfigure $fd -encoding binary -translation binary -blocking 1
  puts -nonewline $fd $bytes
  flush $fd
 } result options]
 set close_code 0
 if {$fd ne ""} {set close_code [catch {close $fd} close_result close_options]}
 if {$code} {
  if {$close_code} {dict append options -errorinfo "\nAdditional owned output close error: $close_result"}
  return -options $options $result
 }
 if {$close_code} {return -options $close_options $close_result}
 set actual [read_binary $path]
 if {[string length $actual] != $length || ![string equal $actual $bytes]} {error "Formal output byte readback mismatch: $path"}
 return $length
}
proc ::formal_file_process::main {arguments} {
 variable maximum_bytes
 if {[llength $arguments] != 2} {error {Expected read/write and one path}}
 lassign $arguments action path
 if {$action eq "read"} {
  set bytes [read_binary $path]
  binary scan $bytes H* hex
  return "GS_FILE_IO_OK READ [string length $bytes] $hex"
 }
 if {$action ne "write"} {error "Unsupported formal file operation: $action"}
 fconfigure stdin -encoding binary -translation binary -blocking 1
 set hex [read stdin [expr {2*$maximum_bytes+1}]]
 set length [string length $hex]
 if {![eof stdin] || $length < 2 || $length > 2*$maximum_bytes || $length % 2 || ![regexp {^[0-9a-f]+$} $hex]} {
  error "Formal HEX input rejected: $length characters"
 }
 set bytes [binary format H* $hex]
 set written [write_binary_new $path $bytes]
 return "GS_FILE_IO_OK WRITE $written"
}
set formal_file_code [catch {
 fconfigure stdout -encoding utf-8 -translation lf -blocking 1
 fconfigure stderr -encoding utf-8 -translation lf -blocking 1
 set formal_file_response [::formal_file_process::main $argv]
 puts stdout $formal_file_response
 flush stdout
} formal_file_result formal_file_options]
if {$formal_file_code} {
 catch {puts stderr "GS_FILE_IO_ERROR: $formal_file_result\nRETURN_OPTIONS: $formal_file_options"; flush stderr}
 exit 1
}
exit 0

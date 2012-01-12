# This program is copyright 2011 Percona Inc.
# Feedback and improvements are welcome.
#
# THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, version 2; OR the Perl Artistic License.  On UNIX and similar
# systems, you can issue `man perlgpl' or `man perlartistic' to read these
# licenses.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307  USA.
# ###########################################################################
# Diskstats package
# ###########################################################################
{
# Package: Diskstats
# This package implements most of the logic in the old shell pt-diskstats;
# it parses data from /proc/diskstats, calculcates deltas, and prints those.

package Diskstats;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use IO::Handle;
use List::Util qw( max first );

my $constants;
BEGIN {
$constants = {
   major               => 0,
   minor               => 1,
   device              => 2,
   reads               => 3,
   reads_merged        => 4,
   read_sectors        => 5,
   ms_spent_reading    => 6,
   writes              => 7,
   writes_merged       => 8,
   written_sectors     => 9,
   ms_spent_writing    => 10,
   ios_in_progress     => 11,
   ms_spent_doing_io   => 12,
   ms_weighted         => 13,
   read_bytes          => 14,
   read_kbs            => 15,
   written_bytes       => 16,
   written_kbs         => 17,
   ios_requested       => 18,
   ios_in_bytes        => 19,
   sum_ios_in_progress => 20,
};

require constant;
constant->import($constants);
}
sub new {
   my ( $class, %args ) = @_;

   my @required_args = qw(OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $o = delete $args{OptionParser};
   # We take OptionParser out of %args, since the latter
   # will be saved inside the new object, and OptionParser
   # is abused by DiskstatsMenu to store the current
   # GroupBy object.

   local $EVAL_ERROR;
   my $self = {
      # Defaults
      filename           => '/proc/diskstats',
      column_regex       => qr/cnc|rt|busy|prg|time|io_s/,
      device_regex       => qr/.+/,
      block_size         => 512,
      output_fh             => \*STDOUT,
      zero_rows          => $o->get('zero-rows')   ?  1 : undef,
      sample_time        => $o->get('sample-time') || 0,
      interactive        => 0,

      %args,

      _stats_for         => {},
      _ordered_devs      => [],
      _ts                => {},
      _first             => 1,

      # Internal for now, but might need APIfying.
      _save_curr_as_prev => 1,
      _print_header      => 1,
   };

   # This next part turns the strings passed in from the command line
   # into actual regexen, but also avoids the case where they entered
   # --devices '' or --columns ''. When qr//'d, those become the empty
   # pattern, which is magical; Instead, we give them what awk would:
   # A pattern that always matches.
   my %pod_to_attribute = (
      columns => 'column_regex',
      devices => 'device_regex'
   );
   for my $key ( grep { defined $o->get($_) } keys %pod_to_attribute ) {
      my $re = $o->get($key) || '.+';
      $self->{ $pod_to_attribute{$key} } = qr/$re/i;
   }

   return bless $self, $class;
}

# The next lot are accessors, plus some convenience functions.

sub curr_ts {
   my ($self) = @_;
   return $self->{_ts}->{curr} || 0;
}

sub set_curr_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{curr} = $val || 0;
}

sub prev_ts {
   my ($self) = @_;
   return $self->{_ts}->{prev} || 0;
}

sub set_prev_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{prev} = $val || 0;
}

sub first_ts {
   my ($self) = @_;
   return $self->{_ts}->{first} || 0;
}

sub set_first_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{first} = $val || 0;
}

sub zero_rows {
   my ($self) = @_;
   return $self->{zero_rows};
}

sub set_zero_rows {
   my ($self, $new_val) = @_;
   $self->{zero_rows} = $new_val;
}

sub sample_time {
   my ($self) = @_;
   return $self->{sample_time};
}

sub set_sample_time {
   my ($self, $new_val) = @_;
   if (defined($new_val)) {
      $self->{sample_time} = $new_val;
   }
}

sub interactive {
   my ($self) = @_;
   return $self->{interactive};
}

sub set_interactive {
   my ($self, $new_val) = @_;
   if (defined($new_val)) {
      $self->{interactive} = $new_val;
   }
}

# Checks whenever said filehandle is open. If it's not, defaults to STDOUT.
sub output_fh {
   my ( $self ) = @_;
   if ( !$self->{output_fh} || !$self->{output_fh}->opened ) {
      $self->{output_fh} = \*STDOUT;
   }
   return $self->{output_fh};
}

# It sets or returns the currently set filehandle, kind of like a poor man's
# select().
sub set_output_fh {
   my ( $self, $new_fh ) = @_;
                  # ->opened comes from IO::Handle.
   if ( $new_fh && ref($new_fh) && $new_fh->opened ) {
      $self->{output_fh} = $new_fh;
   }
}

sub column_regex {
   my ( $self ) = @_;
   return $self->{column_regex};
}

sub set_column_regex {
   my ( $self, $new_re ) = @_;
   return $self->{column_regex} = $new_re;
}

sub device_regex {
   my ( $self ) = @_;
   return $self->{device_regex};
}

sub set_device_regex {
   my ( $self, $new_re ) = @_;
   if ($new_re) {
      return $self->{device_regex} = $new_re;
   }
}

sub filename {
   my ( $self ) = @_;
   return $self->{filename};
}

sub set_filename {
   my ( $self, $new_filename ) = @_;
   if ( $new_filename ) {
      return $self->{filename} = $new_filename;
   }
}

sub block_size {
   my ( $self ) = @_;
   return $self->{block_size};
}

# Returns a list of devices seen. You may pass an arrayref argument to
# replace the internal list, but consider using clear_ordered_devs and
# add_ordered_dev instead.

sub ordered_devs {
   my ( $self, $replacement_list ) = @_;
   if ( $replacement_list ) {
      $self->{_ordered_devs} = $replacement_list;
   }
   return @{ $self->{_ordered_devs} };
}

sub add_ordered_dev {
   my ( $self, $new_dev ) = @_;
   if ( !$self->{_seen_devs}->{$new_dev}++ ) {
      push @{ $self->{_ordered_devs} }, $new_dev;
   }
   return;
}

# clear_stuff methods. Like the name says, they clear state stored inside
# the object.

sub clear_state {
   my ($self) = @_;
   $self->{_first} = 1;
   $self->{_print_header} = 1;
   $self->clear_curr_stats();
   $self->clear_prev_stats();
   $self->clear_first_stats();
   $self->clear_ts();
   $self->clear_ordered_devs();
}

sub clear_ts {
   my ($self) = @_;
   $self->{_ts} = {};
}

sub clear_ordered_devs {
   my ($self) = @_;
   $self->{_seen_devs} = {};
   $self->ordered_devs( [] );
}

sub _clear_stats_common {
   my ( $self, $key, @args ) = @_;
   if (@args) {
      for my $dev (@args) {
         $self->{$key}->{$dev} = {};
      }
   }
   else {
      $self->{$key} = {};
   }
}

sub clear_curr_stats {
   my ( $self, @args ) = @_;
   $self->_clear_stats_common( "_stats_for", @args );
}

sub clear_prev_stats {
   my ( $self, @args ) = @_;
   $self->_clear_stats_common( "_prev_stats_for", @args );
}

sub clear_first_stats {
   my ( $self, @args ) = @_;
   $self->_clear_stats_common( "_first_stats_for", @args );
}

sub stats_for {
   my ( $self, $dev ) = @_;
   $self->{_stats_for} ||= {};
   if ($dev) {
      return $self->{_stats_for}->{$dev};
   }
   return $self->{_stats_for};
}

sub prev_stats_for {
   my ( $self, $dev ) = @_;
   $self->{_prev_stats_for} ||= {};
   if ($dev) {
      return $self->{_prev_stats_for}->{$dev};
   }
   return $self->{_prev_stats_for};
}

sub first_stats_for {
   my ( $self, $dev ) = @_;
   $self->{_first_stats_for} ||= {};
   if ($dev) {
      return $self->{_first_stats_for}->{$dev};
   }
   return $self->{_first_stats_for};
}

sub has_stats {
   my ($self) = @_;
   my $stats  = $self->stats_for;

   for my $key ( keys %$stats ) {
      return 1 if $stats->{$key} && @{ $stats->{$key} }
   }

   return;
}

sub _save_curr_as_prev {
   my ( $self, $curr ) = @_;

   if ( $self->{_save_curr_as_prev} ) {
      $self->{_prev_stats_for} = $curr;
      for my $dev (keys %$curr) {
         $self->{_prev_stats_for}->{$dev}->[sum_ios_in_progress] +=
            $curr->{$dev}->[ios_in_progress];
      }
      $self->set_prev_ts($self->curr_ts());
   }

   return;
}

sub _save_curr_as_first {
   my ($self, $curr) = @_;

   if ( $self->{_first} ) {
      $self->{_first_stats_for} = {
         map { $_ => [@{$curr->{$_}}] } keys %$curr
      };
      $self->set_first_ts($self->curr_ts());
      $self->{_first} = undef;
   }
}

sub trim {
   my ($c) = @_;
   $c =~ s/^\s+//;
   $c =~ s/\s+$//;
   return $c;
}

sub col_ok {
   my ( $self, $column ) = @_;
   my $regex = $self->column_regex();
   return ($column =~ $regex) || (trim($column) =~ $regex);
}

sub dev_ok {
   my ( $self, $device ) = @_;
   my $regex = $self->device_regex();
   return $device =~ $regex;
}

our @columns_in_order = (
   # Column        # Format   # Key name
   [ "   rd_s" => "%7.1f",   "reads_sec", ],
   [ "rd_avkb" => "%7.1f",   "avg_read_sz", ],
   [ "rd_mb_s" => "%7.1f",   "mbytes_read_sec", ],
   [ "rd_io_s" => "%7.1f",   "ios_read_sec", ],
   [ "rd_mrg"  => "%5.0f%%", "read_merge_pct", ],
   [ "rd_cnc"  => "%6.1f",   "read_conc", ],
   [ "  rd_rt" => "%7.1f",   "read_rtime", ],
   [ "   wr_s" => "%7.1f",   "writes_sec", ],
   [ "wr_avkb" => "%7.1f",   "avg_write_sz", ],
   [ "wr_mb_s" => "%7.1f",   "mbytes_written_sec", ],
   [ "wr_io_s" => "%7.1f",   "ios_written_sec", ],
   [ "wr_mrg"  => "%5.0f%%", "write_merge_pct", ],
   [ "wr_cnc"  => "%6.1f",   "write_conc", ],
   [ "  wr_rt" => "%7.1f",   "write_rtime", ],
   [ "busy"    => "%3.0f%%", "busy", ],
   [ "in_prg"  => "%6d",     "in_progress", ],
   [ "   io_s" => "%7.1f",   "s_spent_doing_io", ],
   [ " qtime"   => "%6.1f",   "qtime", ],
   [ " stime"   => "%5.1f",   "stime", ],
);

{

   my %format_for = ( map { ( $_->[0] => $_->[1] ) } @columns_in_order, );

   sub _format_for {
      my ( $self, $col ) = @_;
      return $format_for{$col};
   }

}

{

   my %column_to_key = ( map { ( $_->[0] => $_->[2] ) } @columns_in_order, );

   sub _column_to_key {
      my ( $self, $col ) = @_;
      return $column_to_key{$col};
   }

}

# Method: design_print_formats()
#   What says on the label. Returns three things: the format for the header
#   and the data, and an arrayref of the columns used to make it.
#
# Parameters:
#   %args - Arguments
#
# Optional Arguments:
#   columns             - An arrayref with column names. If absent,
#                         uses ->col_ok to decide which columns to use.
#   max_device_length   - How much space to leave for device names.
#                         Defaults to 6.
#

sub design_print_formats {
   my ( $self,       %args )    = @_;
   my ( $dev_length, $columns ) = @args{qw( max_device_length columns )};
   $dev_length ||= max 6, map length, $self->ordered_devs();
   my ( $header, $format );

   # For each device, print out the following: The timestamp offset and
   # device name.
   $header = $format = qq{%5s %-${dev_length}s };

   if ( !$columns ) {
      @$columns = grep { $self->col_ok($_) } map { $_->[0] } @columns_in_order;
   }
   elsif ( !ref($columns) || ref($columns) ne ref([]) ) {
      die "The columns argument to design_print_formats should be an arrayref";
   }

   $header .= join " ", @$columns;
   $format .= join " ", map $self->_format_for($_), @$columns;

   return ( $header, $format, $columns );
}

{
# This is hot code. In any given run it could end up being called
# thousands of times, so beware: Here could be dragons.

sub parse_diskstats_line {
   my ( $self, $line, $block_size ) = @_;
   my @dev_stats;
   $#dev_stats = 30; # Pre-expand the amount of keys for this array.

#   The following split replaces this:
#         $line =~ /^
#            # Disk format
#               \s*   (\d+)    # major
#               \s+   (\d+)    # minor
#               \s+   (.+?)    # Device name
#               \s+   (\d+)    # # of reads issued
#               \s+   (\d+)    # # of reads merged
#               \s+   (\d+)    # # of sectors read
#               \s+   (\d+)    # # of milliseconds spent reading
#               \s+   (\d+)    # # of writes completed
#               \s+   (\d+)    # # of writes merged
#               \s+   (\d+)    # # of sectors written
#               \s+   (\d+)    # # of milliseconds spent writing
#               \s+   (\d+)    # # of IOs currently in progress
#               \s+   (\d+)    # # of milliseconds spent doing IOs
#               \s+   (\d+)    # weighted # of milliseconds spent doing IOs
#               \s*$/x
#
#   Since we assume that device names can't have spaces.

   # Assigns the first two elements of the list created by split() into
   # %dev_stats as the major and minor, the third element into $dev,
   # and the remaining elements back into %dev_stats.
   if ( 14 == ( @dev_stats = split " ", $line ) ) {
      $dev_stats[read_kbs]    =
         ( $dev_stats[read_bytes] = $dev_stats[read_sectors]
                                  * $block_size ) / 1024;
      $dev_stats[written_kbs] =
         ( $dev_stats[written_bytes] = $dev_stats[written_sectors]
                                     * $block_size ) / 1024;
      $dev_stats[ios_requested] = $dev_stats[reads]
                                + $dev_stats[writes];

      $dev_stats[ios_in_bytes]  = $dev_stats[read_bytes]
                                + $dev_stats[written_bytes];

      return ( $dev_stats[device], \@dev_stats );
   }
   else {
      return;
   }
}
}

# Method: parse_from()
#   Parses data from one of the sources.
#
# Parameters:
#   %args - Arguments
#
# Optional Arguments:
#   filehandle       - Reads data from a filehandle.
#   data             - A normal scalar, opened as a scalar filehandle,
#                      after which it behaves like the above argument.
#   filename         - Opens a filehandle to the file and reads it one
#                      line at a time.
#   sample_callback  - Called each time a sample is processed, passed
#                      the latest timestamp.
#

sub parse_from {
   my ( $self, %args ) = @_;

   my $lines_read;
   if ($args{filehandle}) {
      $lines_read = $self->_parse_from_filehandle(
                        @args{qw( filehandle sample_callback )}
                     );
   }
   elsif ( $args{data} ) {
      open( my $fh, "<", ref($args{data}) ? $args{data} : \$args{data} )
         or die "Couldn't parse data: $OS_ERROR";
      my $lines_read = $self->_parse_from_filehandle(
                        $fh, $args{sample_callback}
                     );
      close $fh or warn "Cannot close: $OS_ERROR";
   }
   else {
      my $filename = $args{filename} || $self->filename();
   
      open my $fh, "<", $filename
         or die "Cannot parse $filename: $OS_ERROR";
      $lines_read = $self->_parse_from_filehandle(
                        $fh, $args{sample_callback}
                     );
      close $fh or warn "Cannot close: $OS_ERROR";
   }

   return $lines_read;
}

# Method: _parse_from_filehandle()
#   Parses data received from using readline() on the filehandle. This is
#   particularly useful, as you could pass in a filehandle to a pipe, or
#   a tied filehandle, or a PerlIO::Scalar handle. Or your normal
#   run of the mill filehandle.
#
# Parameters:
#   filehandle       - 
#   sample_callback  - Called each time a sample is processed, passed
#                      the latest timestamp.
#

sub _parse_from_filehandle {
   my ( $self, $filehandle, $sample_callback ) = @_;
   return $self->_parse_and_load_diskstats( $filehandle, $sample_callback );
}

# Method: _parse_and_load_diskstats()
#   !!!!INTERNAL!!!!!
#   Reads from the filehandle, either saving the data as needed if dealing
#   with a diskstats-formatted line, or if it finds a TS line and has a
#   callback, defering to that.

sub _parse_and_load_diskstats {
   my ( $self, $fh, $sample_callback ) = @_;
   my $block_size = $self->block_size();
   my $current_ts = 0;
   my $new_cur    = {};

   while ( my $line = <$fh> ) {
      # The order of parsing here is intentionally backwards -- While the
      # timestamp line will always happen first, it's actually the rarest
      # thing to find -- Once ever couple dozen lines or so.
      # This matters, because on a normal run, checking for the TS line
      # first ends up in some ~10000 ultimately useless calls to the
      # regular expression engine, and thus a noticeable slowdown;
      # Something in the order of 2 seconds or so, per file.
      if ( my ( $dev, $dev_stats )
               = $self->parse_diskstats_line($line, $block_size) )
      {
         $new_cur->{$dev} = $dev_stats;
         $self->add_ordered_dev($dev);
      }
      elsif ( my ($new_ts) = $line =~ /TS\s+([0-9]+(?:\.[0-9]+)?)/ ) {
         if ( $current_ts && %$new_cur ) {
            $self->_handle_ts_line($current_ts, $new_cur, $sample_callback);
            $new_cur = {};
         }
         $current_ts = $new_ts;
      }
      else {
         chomp($line);
         warn "Line $INPUT_LINE_NUMBER: [$line] isn't in the diskstats format";
      }
   }

   if ( $current_ts && %{$new_cur} ) {
      $self->_handle_ts_line($current_ts, $new_cur, $sample_callback);
      $new_cur = {};
   }
   # Seems like this could be useful.
   return $INPUT_LINE_NUMBER;
}

sub _handle_ts_line {
   my ($self, $current_ts, $new_cur, $sample_callback) = @_;

   $self->_save_curr_as_prev( $self->stats_for() );
   $self->{_stats_for} = $new_cur;
   $self->set_curr_ts($current_ts);
   $self->_save_curr_as_first( $new_cur );

   if ($sample_callback) {
      $self->$sample_callback($current_ts);
   }
   return;
}

sub _calc_read_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group) = @args{ @required_args };

   my %read_stats = (
      reads_sec       => $delta_for->{reads} / $elapsed,
      read_requests   => $delta_for->{reads_merged} + $delta_for->{reads},
      mbytes_read_sec => $delta_for->{read_kbs} / $elapsed / 1024,
      ios_read_sec    => $delta_for->{ms_spent_reading} / 1000,
      read_conc       => $delta_for->{ms_spent_reading} /
                           $elapsed / 1000 / $devs_in_group,
   );

   if ( $delta_for->{reads} > 0 ) {
      $read_stats{read_rtime} =
        $delta_for->{ms_spent_reading} / $delta_for->{reads};
      $read_stats{avg_read_sz} =
        $delta_for->{read_kbs} / $delta_for->{reads};
   }
   else {
      $read_stats{read_rtime}  = 0;
      $read_stats{avg_read_sz} = 0;
   }

   $read_stats{read_merge_pct} =
     $read_stats{read_requests} > 0
     ? 100 * $delta_for->{reads_merged} / $read_stats{read_requests}
     : 0;

   return %read_stats;
}

sub _calc_write_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group) = @args{ @required_args };

   my %write_stats = (
      writes_sec     => $delta_for->{writes} / $elapsed,
      write_requests => $delta_for->{writes_merged} + $delta_for->{writes},
      mbytes_written_sec  => $delta_for->{written_kbs} / $elapsed / 1024,
      ios_written_sec    => $delta_for->{ms_spent_writing} / 1000,
      write_conc         => $delta_for->{ms_spent_writing} /
        $elapsed / 1000 /
        $devs_in_group,
   );

   if ( $delta_for->{writes} > 0 ) {
      $write_stats{write_rtime} =
        $delta_for->{ms_spent_writing} / $delta_for->{writes};
      $write_stats{avg_write_sz} =
        $delta_for->{written_kbs} / $delta_for->{writes};
   }
   else {
      $write_stats{write_rtime}  = 0;
      $write_stats{avg_write_sz} = 0;
   }

   $write_stats{write_merge_pct} =
     $write_stats{write_requests} > 0
     ? 100 * $delta_for->{writes_merged} / $write_stats{write_requests}
     : 0;

   return %write_stats;
}


# Compute the numbers for reads and writes together, the things for
# which we do not have separate statistics.

sub _calc_misc_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group stats );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group, $stats) = @args{ @required_args };
   my %extra_stats;

   # Busy is what iostat calls %util.  This is the percent of
   # wall-clock time during which the device has I/O happening.
   $extra_stats{busy}
      = 100
      * $delta_for->{ms_spent_doing_io}
      / ( 1000 * $elapsed * $devs_in_group ); # Highlighting failure: /

   my $number_of_ios        = $stats->{ios_requested};
   my $total_ms_spent_on_io = $delta_for->{ms_spent_reading}
                            + $delta_for->{ms_spent_writing};

   if ( $number_of_ios ) {
      $extra_stats{qtime} = $total_ms_spent_on_io / $number_of_ios;
      $extra_stats{stime} = $delta_for->{ms_spent_doing_io} / $number_of_ios;
   }
   else {
      $extra_stats{qtime} = 0;
      $extra_stats{stime} = 0;
   }

   $extra_stats{s_spent_doing_io} = $total_ms_spent_on_io / 1000;

   $extra_stats{line_ts} = $self->compute_line_ts(
      first_ts   => $self->first_ts(),
      curr_ts    => $self->curr_ts(),
   );

   return %extra_stats;
}

# An array of arrayefs; the first element of each arrayref is
# the value we are calculating the delta for, while the second
# element is the index in which the value resides.
# Basically, each arrayref is
# [ reads => reads() ]
my @delta_keys = map { [ $_ => $constants->{$_} ] }
         qw( reads reads_merged read_sectors ms_spent_reading
         writes writes_merged written_sectors ms_spent_writing
         read_kbs written_kbs
         ms_spent_doing_io ms_weighted );

sub _calc_delta_for {
   my ( $self, $curr, $against ) = @_;
   my %deltas;

   for my $delta_key (@delta_keys) {
      my ($key, $index) = @$delta_key;
      $deltas{$key} = ($curr->[ $index ]    || 0 )
                    - ($against->[ $index ] || 0 );
   }

   return \%deltas;
}

sub _calc_stats_for_deltas {
   my ( $self, $elapsed ) = @_;
   my @end_stats;
   my @devices = $self->ordered_devs();

   my $devs_in_group = $self->compute_devs_in_group();

   # Read "For each device that passes the dev_ok regex, and we have stats for"
   foreach my $dev ( grep { $self->dev_ok($_) } @devices ) {
      my $curr    = $self->stats_for($dev);
      next unless $curr;
      my $against = $self->delta_against($dev);

      my $delta_for       = $self->_calc_delta_for( $curr, $against );
      my $in_progress     = $curr->[ios_in_progress];
      my $tot_in_progress = $against->[sum_ios_in_progress] || 0;

      # Compute the per-second stats for reads, writes, and overall.
      my %stats = (
         $self->_calc_read_stats(
            delta_for     => $delta_for,
            elapsed       => $elapsed,
            devs_in_group => $devs_in_group,
         ),
         $self->_calc_write_stats(
            delta_for     => $delta_for,
            elapsed       => $elapsed,
            devs_in_group => $devs_in_group,
         ),
         in_progress =>
           $self->compute_in_progress( $in_progress, $tot_in_progress ),
      );

      my %extras = $self->_calc_misc_stats(
         delta_for     => $delta_for,
         elapsed       => $elapsed,
         devs_in_group => $devs_in_group,
         stats         => \%stats,
      );

      @stats{ keys %extras } = values %extras;

      $stats{dev} = $dev;

      push @end_stats, \%stats;
   }
   return @end_stats;
}

sub _calc_deltas {
   my ( $self ) = @_;

   my $elapsed = $self->curr_ts() - $self->delta_against_ts();
   die "Time between samples should be > 0, is [$elapsed]" if $elapsed <= 0;

   return $self->_calc_stats_for_deltas($elapsed);
}

sub print_header {
   my ($self, $header, @args) = @_;
   if ( $self->{_print_header} ) {
      printf { $self->output_fh() } $header . "\n", @args;
   }
}

sub print_rows {
   my ($self, $format, $cols, $stat) = @_;
   if ( ! $self->zero_rows() ) {
      # Conundrum: What is "zero"?
      # Is 0.000001 zero? How about 0.1?
      # Here the answer is "it looks like zero after formatting";
      # unfortunately, we lack the formats at this point. We could
      # fetch them again, but that's a pain, so instead we use
      # %7.1f, which is what most of them are anyway, and should
      # work for nearly all cases.
      return unless grep {
            sprintf("%7.1f", $_) != 0
         } @{ $stat }{ @$cols };
   }
   printf { $self->output_fh() } $format . "\n",
           @{ $stat }{ qw( line_ts dev ), @$cols };
}

sub print_deltas {
   my ( $self, %args ) = @_;

   my ( $header, $format, $cols ) = $self->design_print_formats(
      # Not required args, because design_print_formats picks sane defaults.
      max_device_length => $args{max_device_length},
      columns           => $args{columns},
   );

   return unless $self->delta_against_ts();

   @$cols = map { $self->_column_to_key($_) } @$cols;

   my $header_method = $args{header_callback} || "print_header";
   my $rows_method   = $args{rows_callback}   || "print_rows";

   $self->$header_method( $header, "#ts", "device" );

   foreach my $stat ( $self->_calc_deltas() ) {
      $self->$rows_method( $format, $cols, $stat );
   }
}

sub compute_line_ts {
   my ( $self, %args ) = @_;
   return sprintf( "%5.1f", $args{first_ts} > 0
                            ? $args{curr_ts} - $args{first_ts}
                            : 0 );
}

sub compute_in_progress {
   my ( $self, $in_progress, $tot_in_progress ) = @_;
   return $in_progress;
}

sub compute_devs_in_group {
   return 1;
}

sub delta_against {
   die 'You must override delta_against() in a subclass';
}

sub delta_against_ts {
   die 'You must override delta_against_ts() in a subclass';
}

sub group_by {
   die 'You must override group_by() in a subclass';
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;

}
# ###########################################################################
# End Diskstats package
# ###########################################################################

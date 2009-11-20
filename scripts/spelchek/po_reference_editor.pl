#!/usr/bin/perl -w
use strict;
use warnings;
use Data::Dumper;
use File::Basename;
use Config::General;
use FindBin qw($Bin);
use Term::ANSIColor;

use lib "$Bin";
use Spelchek;

my %conf = %{Spelchek::get_config()};

my $misspelled = $ARGV[0];
my $po_line = $ARGV[1];
my $references = $ARGV[2];
$references =~ s/([^\\]),/$1\n/g;

my $base_dir = $ENV{BASE_DIR} || '.';

sub todo {
	Spelchek::todo(@_);
}

sub get_sql_update_statement {
	my ($meta, $misspelled) = @_;
}

sub edit_db {
	Spelchek::edit_mysql_update_file($conf{text_editor}, @_);
	Spelchek::edit_sql($conf{text_editor}, @_);
}

if (scalar @ARGV != 3) {
	my $me = basename(__FILE__);
	print "Usage: $me <wrongword> <reference1,...>\n";
	exit 1;
}

foreach my $reference (split(/\n/, $references)) {

	Spelchek::notify_action("Editing $reference");

	my $source = Spelchek::reference_to_meta($reference);

	if ($source->{type} eq 'DB') {
		edit_db($source->{meta}, $misspelled, $po_line);
	}
	elsif ($source->{type} eq 'FILE') {
		Spelchek::edit_file(
				$conf{text_editor},
				$base_dir . '/' . $source->{meta}->{filename},
				$source->{meta}->{line_no},
				$misspelled
			);
	}
}

#!/usr/bin/perl -w
use strict;
use warnings;
use Data::Dumper;
use File::Basename;
use Config::General;
use FindBin qw($Bin);
use Term::ANSIColor;
use File::Spec::Functions;

use lib "$Bin";
use Spelchek;
my $spellcheck_fix_sql_file = $Spelchek::spellcheck_fix_sql_file;

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
	my ($meta, $misspelled, $po_line) = @_;
	Spelchek::add_MySQL_update_statement_to_file(
			$spellcheck_fix_sql_file,
			$meta,
			$misspelled,
			$po_line,
		);

	Spelchek::edit_file(
			$conf{text_editor},
			$spellcheck_fix_sql_file,
			Spelchek::get_last_line_no($spellcheck_fix_sql_file),
			$misspelled
		);

	my ($table_sql_file, $line_no) = Spelchek::get_sql_file_and_line_for($meta);
	Spelchek::edit_file(
			$conf{text_editor},
			$table_sql_file,
			$line_no,
			$misspelled
		);
}

if (scalar @ARGV != 3) {
	my $me = basename(__FILE__);
	print "Usage: $me <wrongword> <reference1,...>\n";
	exit 1;
}

foreach my $reference (split(/\n/, $references)) {

	Spelchek::notify_action("Editing '$reference'");

	my @sources = Spelchek::reference_to_meta($reference);

	foreach my $source (@sources) {
		if ($source->{type} eq 'DB') {
			edit_db($source->{meta}, $misspelled, $po_line);
		}
		elsif ($source->{type} eq 'FILE') {
			Spelchek::edit_file(
					$conf{text_editor},
					catfile($base_dir, $source->{meta}->{filename}),
					$source->{meta}->{line_no},
					$misspelled
					);
		}
	}
}

#!/usr/bin/perl
use strict;
use warnings;
use Carp qw/croak/;
use Config::General;
use Config::General;
use Data::Dumper;
use English;
use File::Basename;
use File::Slurp qw/slurp/;
use FindBin qw($Bin);
use Getopt::Std;
use HTML::Strip;
use IO::Prompt;
use Locale::PO 0.21;
use Regexp::Common;
use Term::ANSIColor;
use Text::Aspell;
use Term::ReadKey;

use lib "$Bin";
use Spelchek;

my %opts;
my $valid_option = getopts('sued:', \%opts);
# -u    'do not show unknown word list'
# -s    'summary (wordcount) only'
# -d n  'debug level is n'
my $opt_summary_only = 0;
my $opt_debug_level = 0;
my $opt_exit_value = 0;
my $opt_show_unknown_word_list = 1;

my $pristine_msgstr;
my $current_msgstr_cleaned;
my $current_msgstr_stripped;
my $punctuations_removed;
my $digits_removed;
my $dashes_and_quotes_removed;
my %conf;

my $LONGEST_COMMAND_LENGTH = 0;
my $TERMINAL_WIDTH = 80;
my $HALF_WIDTH = 36;
my $LANGUAGE = $ARGV[0];
my $LOCAL_DICT_FILE = "dict/$LANGUAGE.txt";
my $ABBREVIATION_FILE = "dict/$LANGUAGE.abbr.txt";
my $IGNORED_PHRASES_FILE = "dict/$LANGUAGE.ignore.phrases.txt";
my @IGNORED_PHRASES;
my $PERSONAL_DICT_FILE = undef;
my $PERSONAL_DICT_FILE_MANGLED = undef;
my $COMMON_DICT_FILE = 'dict/common.txt';
my $MISSPELLED_COLOR = 'white on_red';
my $DB_COLOR = 'blue on_white';
my $CORRECTED_COLOR  = 'black on_green';
my %internal_dict_has;
my %replace_all;
my %ignored_phrase_count_for;
my $statistics_for = {
	total_word_count => 0,
	incorrect_word_count => 0,
	ignored_word_count => 0,
	};

my @external_commands;
my @action_list;
my $spellcheckrc = $Spelchek::spellcheckrc;
my $GIVEN_TEXT = '';
# Limit suggestions to 10, like aspell
my $MAX_SUGGEST = 10;

load_spellcheckrc();

if (defined $opts{s}) {
	$opt_summary_only = 1;
}
if (defined $opts{d}) {
	$opt_debug_level = int($opts{d});
}
if (defined $opts{u}) {
	$opt_show_unknown_word_list = 0;
}
if (defined $opts{e}) {
	$opt_exit_value = 1;
}

my $me = basename(__FILE__);
if (! $valid_option || ! defined $ARGV[0] ) {
	print "Usage: " . $me . " [-s] [-d <debug level>] <language>\n";
	print "Example: " . $me . " en_US\n";
	exit 1;
}

sub print_usage {
	my $default_text_e = $conf{text_editor};
	$default_text_e =~ s//^M/;

	if ($opt_summary_only) {
		print "Please specify a language. e.g.:\n";
		print "make wordcount LANGUAGE=en_US\n";
		return;
	}

	my $usage_text = "
SPELLCHECK HOWTO
----------------

CUSTOMIZATION
=============
$me can be customized via ~/.spellcheckrc.
Valid configuration entries in ~/.spellcheckrc are:

  1. text_editor = command arguments ...

     The following patterns in 'text_editor' will be mangled:

          PATTERN         REPLACEMENT
        %{filename}     The filename
        %{line}         The line number containing the word
        %{wrongword}    The misspelled word

     The default text_editor value is

       $default_text_e

     This opens the file in vi, goes to the line number and moves the cursor
     to the first match of the misspelled word.

     text_editor will be used when editing po files. For editing references
     to msgids (e.g., #: path/to/file.html:22), see po_reference_editor below.

  2. <external_command>
          shortcut = <a single letter>
          description = Descriptive text
          command = command arguments ...
          continue = <0 or 1>
     </external_command>

     More than one <external_command> entries are accepted.
     The 'command' entries in each <external_command> entries will be mangled
     using the following patterns:

          PATTERN            REPLACEMENT
        %{references}      The reference for the msgid in the po file.
                           If there are more than one references, they will be
                           joined with the comma character. Commas in the
                           reference itself will be escaped with backslash (\,).

        %{wrongword}       The misspelled word

        %{po_line}         The line number of the corresponding msgstr where the
                           misspelled word is found.

     The 'continue' entry tells spellcheck whether to continue checking the next
     misspelled word, or recheck the current misspelled word. An example of
     external_command entry for googling the misspelled word is given below:

     <external_command>
         shortcut = g
         description = Google it
         command = lynx \"http://www.google.com/search?q=%{wrongword}\"
         continue = 0
     </external_command>

  3. personal_dictionary = /path/to/your/personal/dictionary.txt

     If defined, $me will also use the specified personal_dictionary.

  4. po_reference_editor = command arguments ...

     The value of po_reference_editor will be mangled in the same way as the 'command'
     entry in external_command.

     Default value:

       po_reference_editor.pl %{wrongword} %{po_line} %{references}

To show wordcount statistics:
=============================

   \$ make wordcount LANGUAGE=en_US

To begin spellchecking:
=======================

    \$ make spellcheck LANGUAGE=en_US

    or

    \$ make spellcheck LANGUAGE=ms_MY

Quick guide on choosing which dictionary to save unknown word to:
=================================================================

  1. Add to ./dict/\$LANG.abbr.txt if it is a valid abbreviation. spelcheck.pl
     will honor the case sensitivity of the abbreviation: If you add 'BMI' into
     it, 'BMI' will be considered as a correct word while 'bmi' is not.

  2. Add to ./dict/\$LANG.abbr.txt if it is a valid word for the language.

  3. Add to ./dict/common.txt if it is a valid word for all languages. Examples of
     words that are valid for all languages are \$FULLNAME\$, VAR_NAME, etc.

  4. If it's none of the above, then put it into your personal_dictionary (see
     CUSTOMIZATION above).

Ignored Phrases
===============

The dict directory also has files named \$LANGUAGE.ignore.phrases.txt.  You may
add phrases into this file during the spellchecking process and the whole
phrase will be ignored in the future. Any obsolete ignored phrases (no longer
encountered) will be reported at the end spellcheck session so that
\$LANGUAGE.ignore.phrases.txt can be kept up to date.


Have fun spellchecking!
";
	my $PAGER;
	if (open $PAGER, "|less") {
		print $PAGER $usage_text;
		close $PAGER;
	}
	elsif (open $PAGER, "|more") {
		print $PAGER $usage_text;
		close $PAGER;
	}
	else {
		print $usage_text;
	}
}

if ($ARGV[0] eq 'ALL_SUPPORTED_LANGUAGES') {
	print_usage();
	exit 0;
}

sub notify_action {
	Spelchek::notify_action(shift);
}

sub lowercase {
	my $text = shift;
	$text =~ tr/A-Z/a-z/;
	return $text;
}

sub load_spellcheckrc {
	%conf = %{Spelchek::get_config()};

	my $external_command_entry = $conf{external_command};
	if (defined $external_command_entry) {
		if (ref $external_command_entry eq 'ARRAY') {
			@external_commands = @{$external_command_entry};
		} else {
			@external_commands = ($external_command_entry);
		}
	}
	if (defined $conf{personal_dictionary}) {
		$PERSONAL_DICT_FILE = $conf{personal_dictionary};
		$PERSONAL_DICT_FILE_MANGLED = $PERSONAL_DICT_FILE;
		$PERSONAL_DICT_FILE_MANGLED =~ s/^~/$ENV{HOME}/;
	}
}

sub debug {
	my ($text, $level) = @_;
	$level ||= 1;
	if ($opt_debug_level >= $level) {
		print colored ['yellow on_black'], "DEBUG: " . $text;
	}
}

sub add_to_internal_dict {
	my ($misspelled, $case_sensitive) = @_;
	$case_sensitive ||= 0;

	if (! $case_sensitive) {
		$misspelled = lowercase($misspelled);
	}

	$internal_dict_has{$misspelled} = 1;

}

sub action_handler_ignore_all {
	my ($speller, $misspelled, $po) = @_;

	# This will be used as suggestion later as per Text::Aspell documentation
	$speller->add_to_session($misspelled);

	add_to_internal_dict($misspelled);
	notify_action "Ignoring '$misspelled'.";
	if (! defined $statistics_for->{ignored_word}->{$misspelled}) {
		$statistics_for->{ignored_word_count} += 1;
	}
	$statistics_for->{ignored_word}->{$misspelled} += 1;

	return 1;
}

sub todo {
	Spelchek::todo(@_);
}

sub join_references {
	my $references = shift;

	$references =~ s/,/\\,/gxms;
	return join(',', split(/\n/, $references));
}

sub edit_en_US_source {
	# Note: The following only apply to en_US
	my ($po, $misspelled, $po_line) = @_;

	my $reference  = join_references($po->reference());

	my $cmd = $conf{po_reference_editor};
	$cmd =~ s/%{wrongword}/$misspelled/g;
	$cmd =~ s/%{po_line}/$po_line/g;
	$cmd =~ s/%{references}/$reference/g;

	return Spelchek::run_cmd($cmd);
}

sub get_po_line {
	my ($msgid_needle, $for_msgstr) = @_;

	my $po_file = "$LANGUAGE.po";

	open my $PO_FILE, '<', $po_file
		or die "Could not open $po_file: $OS_ERROR";
	my $line_no = 0;
	my $msgid_line_no = 0;
	my $msgstr_line_no = 0;
	my $wanted_line_no;
	while (my $line = <$PO_FILE>) {
		$line_no += 1;
		if ($line =~ /^msgid/) {
			$msgid_line_no = $line_no;
			chomp $line;
			$line =~ s/^msgid "//;
			$line =~ s/"$//;
			my $msgid = $line;
			while (my $nextline = <$PO_FILE>) {
				$line_no += 1;
				chomp $nextline;
				if ($nextline !~ /^msgstr/) {
					$nextline =~ s/^"//;
					$nextline =~ s/"$//;
					$msgid .= $nextline;
				} else {
					$msgstr_line_no = $line_no;
					if ($msgid_needle eq "\"$msgid\"") {
						debug "NEEDLE \n[$msgid_needle]\n";
						debug "MSGID  \n[$msgid]\n";
						debug "line_no is [$line_no]\n";
						if (defined $for_msgstr) {
							debug("returning for msgstr: $msgstr_line_no\n");
							return $msgstr_line_no;
						} else {
							debug("returning for msgsid: $msgid_line_no\n");
							return $msgid_line_no;
						}
					}
					last;
				}
			}
		}
	}

	die "Couldn't get line no for msgid '$msgid_needle' in $po_file";
}

sub edit_po_file {
	my ($po, $misspelled) = @_;
	my $line_no = get_po_line($po->msgid(), 'for msgstr');
	my $file = "$LANGUAGE.po";
	notify_action("Editing $file");
	Spelchek::edit_file($conf{text_editor}, "$LANGUAGE.po", $line_no, $misspelled);
}

sub action_handler_edit_source {
	my ($speller, $misspelled, $po, $original_word) = @_;
	my $success = 1;

	if ($LANGUAGE eq 'en_US') {
		my $po_line = get_po_line($po->msgid());
		$success = edit_en_US_source($po, $misspelled, $po_line);
	} else {
		my $po_line = get_po_line($po->msgid(), 'for msgstr');
		$success = edit_po_file($po, $original_word, $po_line);
	}

	return $success;
}

sub create_local_dict_file {
	my ($dict_file, $header) = @_;
	open my $LOCALDICT, '>', $dict_file
		or die "Could not open $dict_file: $OS_ERROR";
	print $LOCALDICT $header . "\n";
	close $LOCALDICT;
}

my $need_sort_local_dict = 0;
my $need_sort_common_dict = 0;
my $need_sort_abbreviation_dict = 0;
my $need_sort_personal_dict = 0;

sub add_to_file_dict {
	my ($speller, $misspelled, $dict_file, $header) = @_;
	$speller->add_to_session($misspelled);

	if ( ! -d './dict' ) {
		`mkdir ./dict`;
	}

	if ( ! -f $dict_file ) {
		create_local_dict_file($dict_file, $header);
	}

	open my $LOCALDICT, '>>', $dict_file
		or die "Could not open $dict_file: $OS_ERROR";
	print $LOCALDICT $misspelled . "\n";
	close $LOCALDICT;
	notify_action("'$misspelled' added to $dict_file");
}

sub action_handler_add_to_lang_dict {
	my ($speller, $misspelled) = @_;
	$need_sort_local_dict = 1;

	my $dict_file = $LOCAL_DICT_FILE;
	my $header = "# $LANGUAGE word list, one per line, case insensitive";

	add_to_file_dict($speller, lowercase($misspelled), $dict_file, $header);
	add_to_internal_dict($misspelled);
}

sub action_handler_add_to_personal_dict {
	my ($speller, $misspelled) = @_;
	$need_sort_personal_dict = 1;

	my $dict_file = $PERSONAL_DICT_FILE_MANGLED;

	my $header = "# personal dictionary, case sensitive";

	add_to_file_dict($speller, $misspelled, $dict_file, $header);
	my $case_sensitive = 1;
	add_to_internal_dict($misspelled, $case_sensitive);
}

sub action_handler_add_to_common_dict {
	my ($speller, $misspelled) = @_;
	$need_sort_common_dict = 1;

	my $dict_file = $COMMON_DICT_FILE;
	my $header = "# Common word list for all languages, case sensitive";

	add_to_file_dict($speller, $misspelled, $dict_file, $header);
	my $case_sensitive = 1;
	add_to_internal_dict($misspelled, $case_sensitive);
}

sub action_handler_add_to_abbreviation_dict {
	my ($speller, $misspelled, $po) = @_;
	$need_sort_abbreviation_dict = 1;

	my $dict_file = $ABBREVIATION_FILE;
	my $header = "# $LANGUAGE abbreviations, case sensitive";

	add_to_file_dict($speller, $misspelled, $dict_file, $header);
	my $case_sensitive = 1;
	add_to_internal_dict($misspelled, $case_sensitive);
}

sub show_unknown_word_list_statistics {
	my ($header, $stat_key, @unknown_words) = @_;
	my @frequency;
	print_header(" $header ");
	print "NO.  FREQUENCY  $header\n";
	foreach my $misspelled (@unknown_words) {
		push @frequency,
			 {
				 frequency => $statistics_for->{$stat_key}->{$misspelled},
				 misspelled => $misspelled,
			 }
	}
	my $total_occurrence = 0;
	my $c = 1;
	foreach my $entry (sort { $a->{frequency} <=> $b->{frequency} } @frequency) {
		printf  "%-3d %5d       %s\n", $c, $entry->{frequency}, $entry->{misspelled} ;
		$total_occurrence += $entry->{frequency};
		$c += 1;
	}
}

sub show_statistics {
	print_header(' PO FILE ');
	print "  $LANGUAGE.po\n";

	my $ignored_but_unmet = '';
	foreach my $ignored_phrase (keys %ignored_phrase_count_for) {
		my $frequency = $ignored_phrase_count_for{$ignored_phrase};
		if ($frequency == 0) {
			$ignored_but_unmet .= "  $ignored_phrase\n";
		}
	}

	if (length $ignored_but_unmet) {
		print_header(" UNMATCHED IGNORED PHRASES ($IGNORED_PHRASES_FILE) ");
		print $ignored_but_unmet;
	}

	if ($opt_summary_only) {
		my @unknown_words = (keys %{$statistics_for->{misspelled_word}});
		if (    $statistics_for->{incorrect_word_count}
			 && $opt_show_unknown_word_list ) {
			show_unknown_word_list_statistics(
					'UNKNOWN WORDS',
					'misspelled_word',
					@unknown_words
				);
		}

		print_header(" $LANGUAGE ");
		printf "  %7d words", $statistics_for->{total_word_count};
		my $unknown_word_count = scalar @unknown_words;
		if ($unknown_word_count > 0) {
			printf ",\n  %7d unknown, %d occurrence",
				   scalar @unknown_words,
				   $statistics_for->{incorrect_word_count},
				   ;
			if ($statistics_for->{incorrect_word_count} > 1) {
				print 's';
			}
		}
		else {
			print '.';
		}
		print "\n";
	}
	else {
		my @ignored_words = (keys %{$statistics_for->{ignored_word}});

		if ( $statistics_for->{ignored_word_count} ) {
			show_unknown_word_list_statistics(
					'IGNORED WORDS',
					'ignored_word',
					@ignored_words
				);
		}

		print_header(' SUMMARY ');
		my $c = 0;
		foreach my $key (sort keys %{$statistics_for->{replacements}}) {
			my $frequency = $statistics_for->{replacements}->{$key};
			$c += $frequency;
			printf "  $key: $frequency time";
			if ($frequency > 1) {
				print "s";
			}
			print ".\n";
		}
		if ($statistics_for->{incorrect_word_count} == 0) {
			my $total_word_count = $statistics_for->{total_word_count};
			if ($total_word_count > 0) {
				print "  Excellent! $total_word_count words, with 0 misspelling. :)\n";
			} else {
				print "  $LANGUAGE has 0 translation.\n";
			}
		} else {
			print "  Total $c replacements.\n";
			print "  (Excludes edits)\n";
		}
	}
}

sub action_handler_exit {
	my $case_sensitive = 1;

	if ($need_sort_local_dict) {
		sort_and_remove_duplicate($LOCAL_DICT_FILE);
	}
	if ($need_sort_common_dict) {
		sort_and_remove_duplicate($COMMON_DICT_FILE, $case_sensitive);
	}
	if ($need_sort_abbreviation_dict) {
		sort_and_remove_duplicate($ABBREVIATION_FILE, $case_sensitive);
	}
	if ($need_sort_personal_dict) {
		sort_and_remove_duplicate($PERSONAL_DICT_FILE_MANGLED, $case_sensitive);
	}
	show_statistics();
	if ($opt_exit_value) {
		my @unknown_words = (keys %{$statistics_for->{misspelled_word}});
		exit scalar @unknown_words;
	}
	else {
		# Always return 0 so that make does not complain
		exit 0;
	}
}

sub sort_and_remove_duplicate {
	my ($dict_file, $case_sensitive) = @_;
	$case_sensitive ||= 0;

	if (! -f $dict_file) {
		return;
	}

	open my $DICT, '<', $dict_file
		or die "Could not open $dict_file: $OS_ERROR";
	my $comment = '';
	my %comment_for;
	my @sorted;
	my $header = <$DICT>;
	while (my $line = <$DICT>) {
		if ($line =~ /^\s*#/) {
			$comment .= $line;
		} else {
			if (! $case_sensitive) {
				$line = lowercase($line);
			}
			push @sorted, $line;
			if (defined $comment_for{$line}) {
				$comment_for{$line} .= $comment;
			} else {
				$comment_for{$line} = $comment;
			}
			$comment = '';
		}
	}
	close $DICT;

	@sorted = sort @sorted;

	$DICT = undef;
	open $DICT, '>', $dict_file
		or die "Could not open $dict_file: $OS_ERROR";

	my %printed;

	print $DICT $header;
	foreach my $line (@sorted) {
		if (defined $printed{$line}) {
			next;
		}
		if (defined $comment_for{$line}) {
			print $DICT $comment_for{$line};
		}
		print $DICT $line;
		$printed{$line} = 1;
	}
	close $DICT;
}

sub read_text {
	my $c = shift;
	my $text = '';
	# my $default = ''; #chr(127);
	my $erase_char = chr(127);
	while (length $c) {
		if ($c ne $erase_char) {
			$text .= $c;
			print $c;
		}
		else {
			if (length $text) {
				substr($text, -1) = '';
				print "\b \b";
			}
			if (length $text == 0) {
				return read_one_char_or_line();
			}
		}
		$c = prompt(-'prompt' => '',
				-tty,
				-onechar,
				#-default => $default,
				#-newline => '',
				-echo => '',
				);
	}
	return $text;
}

sub read_one_char {
	my $c;
	$c = prompt(-'prompt' => '', -tty, -onechar, -echo => '');
	return $c;
}

sub read_one_char_or_line {
	my $c = read_one_char();
	# We no longer show more than 10 suggestions
	# if ($c =~ /^\d$/) {
	# 	return read_text($c);
	# }

	if ($c =~ /^(r|P)$/) {
		return read_text($c);
	}

	print "$c\n";
	return $c;
}


sub get_action {
	my %action_for =  @action_list;

	my $acceptable_actions = join ('|', keys %action_for);

	my $action = '';
	while ($action !~ /^($acceptable_actions)$/) {
		if (length $action) {
			print colored ['white on_red'],"Unknown action '$action'\n";
		}
		my $c = 0;
		for my $i (0 .. scalar @action_list / 2 - 1) {
			my $key = $action_list[$i * 2];
			my $text = $action_list[$i * 2 + 1]->{text};
			printf "%2s) %-${LONGEST_COMMAND_LENGTH}s", $key, $text;
			$c += 1;
			if ($c % 2 == 0) {
				print "\n";
			}
		}
		if ($c % 2) {
			print "\n";
		}
		print "Action: ";

		$action = read_one_char_or_line();

		if (length $action == 0) {
			$action = 'i';
		}

		if ($action =~ /^[0-9]+$/) {
			return $action;
		}
		if ($action =~ /^r/) {
			my ($a, $text) = split(/\s/, $action, 2);
			$text =~ s/^\s+//;
			$text =~ s/\s+$//;
			$GIVEN_TEXT = $text;
			$action = $a;
		} elsif ($action =~ /^P/) {
			my ($a, $text) = split(/\s/, $action, 2);
			$text =~ s/^\s+//;
			$text =~ s/\s+$//;
			$GIVEN_TEXT = $text;
			$action = $a;
		}
	}

	return $action_for{$action};
}

sub print_header {
	my $text = shift;
	my $pre = "--$text";
	my $len = length($pre);
	print $pre,'-' x ($TERMINAL_WIDTH - $len),"\n";
}

sub print_suggestions {
	my @candidates = @_;
	my %suggested_for;

	my $nrows = @candidates;

	if (scalar @candidates % 2 == 1) {
		$nrows += 1;
	}
	$nrows = $nrows / 2;

	my $c;
	my $left;
	my $right;
	if ($nrows) {
		print_header('SUGGESTIONS');
	}

	foreach my $i (0 .. $nrows - 1) {
		$c = $i + 1;
		$left = '';
		$right = '';
		if (defined $candidates[$i]) {
			$left =  " $c) " . $candidates[$i];
			$suggested_for{$c} = $candidates[$i];
		}
		$c = $i + 1 + $nrows;
		if ($c == $MAX_SUGGEST) {
			$c = 0;
		}
		if (defined $candidates[$i + $nrows]) {
			$right = " $c) " . $candidates[$i + $nrows];
			$suggested_for{$c} = $candidates[$i + $nrows];
		}
		printf "%-${HALF_WIDTH}s%-${HALF_WIDTH}s\n", $left, $right;
	}
	return \%suggested_for;
}

#sub to_hex_regex {
#	my $text = shift;
#	$text =~ s/(.)/sprintf('\\x%02x', ord($1))/ge;
#	return $text;
#}

sub highlight {
	my ($color, $misspelled, $text) = @_;
	$text =~ s/((\\[nt]|[^[:alpha:]])*)\Q$misspelled\E(([^[:alpha:]])*)/"$1".color($color).$misspelled.color('reset')."$3"/sge;
	return $text;
}

sub insert_line_number {
	my ($line_no, $line) = @_;
	return sprintf("%d: %s", $line_no, $line);
}

sub show_context_lines {
	my ($misspelled, $file_meta, $ncontext) = @_;
	my $filename   = $file_meta->{filename};
	my $line_no = $file_meta->{line_no};

	my $fullpath = $filename;

	print_header(" $fullpath : $line_no ");

	my $IN;
	if (! open $IN, '<', $fullpath) {
		print STDERR colored['red'],"Warning: Could not open $fullpath: $OS_ERROR";
		print STDERR "\n";
		return;
	}

	my $to_show = '';
	my $c = 0;
	my $found_a_match = 0;

	# Earlier, we replaced all [!,().] with a space
	# $misspelled =~ s/ /./g;

	my $line_count_after_match = 0;

	my $text_of_last_match;
	my $line_no_of_last_match = 0;
	while (my $line = <$IN>) {
		$c += 1;

		if ($line =~ /[^[:alpha:]]*\Q$misspelled\E[^[:alpha:]]*/) {
			# sometimes the line number in po->reference is not exactly where
			# c.loc is, e.g:
			# [% c.loc("
			#      %1 blah %2 blah
			#     ", 'a', 'b') %] <-- this is the line number reported
			# Hence the following work-around:
			$line_no_of_last_match = $c;
			$text_of_last_match = $line;
		}
		next if ($c < $line_no);

		$to_show .= insert_line_number($c, $line);

		if ($line =~ /[^[:alpha:]]\Q$misspelled\E[^[:alpha:]]/) {
			$found_a_match = 1;
		}
		if ($c > $line_no) {
			if ($line =~ /(c\.|->)loc\W/) {
				last;
			}
			# The following works only in TT files
			if ($line =~ /%]/) {
				last;
			}
			# Safeguard against pm files
			if ($found_a_match) {
				$line_count_after_match += 1;
				if ($line_count_after_match > $ncontext) {
					last;
				}
			}
		}

		last if ($c > $line_no && $line =~ /c\.loc\s*\(/);
	}
	close $IN;
	#my $hex_representation = to_hex_regex($misspelled);
	#debug ("hex repreentation is '$hex_representation'\n");
	#$to_show =~ s/([^[:alpha:]])$hex_representation([^[:alpha:]])/"$1".color($MISSPELLED_COLOR).$misspelled.color('reset')."$2"/sge;
	if ($found_a_match) {
		print highlight($MISSPELLED_COLOR, $misspelled, $to_show);
	} else {
		if ($line_no_of_last_match) {
			$text_of_last_match = highlight($MISSPELLED_COLOR, $misspelled, $text_of_last_match);
			printf("%d: %s\n", $line_no_of_last_match, $text_of_last_match);
		} else {
			print colored ['red on_white'],
				  "Could not find $misspelled in $filename:$line_no,\nmaybe the po file is outdated?";
			print "\n";
		}
	}
	#print `$to_show | ack -C $ncontext --color -Q '$misspelled'`;

}

sub show_db_content {
	my ($misspelled, $meta) = @_;

	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};
	print color($DB_COLOR) . 'DB entry' . color('reset') . ': '
		. "TABLE '$table' PRIMARY KEY '$primary_key_column' = '$primary_key_value' COLUMN '$column_name'\n";
	print color($DB_COLOR) . 'Fulltext' . color('reset') . ': ';
	print highlight($MISSPELLED_COLOR, $misspelled, $pristine_msgstr . "\n");
}

sub show_sources {
	my ($misspelled, $po) = @_;

	# print "Showing sources fo \'$misspelled\'\n";
	foreach my $source (Spelchek::get_source_meta($po->reference())) {
		if ($source->{type} eq 'DB') {
			show_db_content($misspelled, $source->{meta});
		} elsif ($source->{type} eq 'FILE') {
			my $CONTEXT_LINES = 13; # just because.
			show_context_lines(
					$misspelled,
					$source->{meta},
					$CONTEXT_LINES
				);
		} else {
			print "Unknown source type: " . $source->{type} . "\n";
		}
	}
}

sub replace_en_US_db_content {
	my ($meta, $po_line, $misspelled, $suggested_word) = @_;

	my $spellcheck_fix_sql_file = $Spelchek::spellcheck_fix_sql_file;
	my ($original, $sql_statement)
		= Spelchek::add_MySQL_update_statement_to_file(
			$spellcheck_fix_sql_file,
			$meta,
			$misspelled,
			$po_line,
			$suggested_word
		);

	print highlight($MISSPELLED_COLOR, $misspelled, $original) . "\n";
	print highlight($CORRECTED_COLOR,  $suggested_word, $sql_statement) . "\n";
	notify_action(
		  "'$misspelled' -> '$suggested_word' in "
		. $spellcheck_fix_sql_file
		. ':'
		. Spelchek::get_last_line_no($spellcheck_fix_sql_file)
		)
		;
	# Spelchek::edit_MySQL_update_file(
	# 		$conf{text_editor},
	# 		$meta,
	# 		$misspelled,
	# 		$po_line,
	# 		$suggested_word
	# 	);

	#print colored ['black on_yellow'],
		  #"TABLE $table PRIMARY KEY $primary_key_column = $primary_key_value COLUMN $column_name\n";

	my $sql_line_no = Spelchek::get_sql_line_for($meta);
	return replace_first_occurrence(
			$Spelchek::sql_file,
			$sql_line_no,
			$misspelled,$suggested_word
		);
}

sub replace_misspelling {
	my ($misspelled, $replacement, $text) = @_;

	$text =~ s/(\\[nt]|[^[:alpha:]]*)$misspelled([^[:alpha:]]*)/$1$replacement$2/;

	return $text;
}

sub replace_first_occurrence {
	my ($fullpath, $line_no, $misspelled, $suggested_word) = @_;
	# debug "Replace first $misspelled with $suggested_word in $fullpath starting at $line_no\n";
	open my $TEXT_FILE, '<', $fullpath
		or die "Could not open $fullpath: $OS_ERROR";

	my @lines = <$TEXT_FILE>;
	my $replacement_done_at = 0;
	my $progress_report = '';
	for my $c ($line_no - 1 .. scalar @lines - 1) {
		my $orig_line = $lines[$c];
		if ($lines[$c] =~ /(\\[nt]|[^[:alpha:]])$misspelled[^[:alpha:]]/) {
			$lines[$c] = replace_misspelling($misspelled, $suggested_word, $lines[$c]);
			if ($lines[$c] ne $orig_line) {
				$replacement_done_at = $c + 1;
				$progress_report
					= "Updated $fullpath:\n"
				      . highlight($MISSPELLED_COLOR, $misspelled, insert_line_number($c + 1, $orig_line))
					  . highlight($CORRECTED_COLOR, $suggested_word, insert_line_number($c + 1, $lines[$c]));
				debug "Replaced:\n";
				debug "Orig line: $orig_line\n";
				debug " New line: " . $lines[$c] . "\n";
			}
			last;
		}
	}

	close $TEXT_FILE;

	$TEXT_FILE = undef;
	open $TEXT_FILE, '>', $fullpath
		or die "Could not open $fullpath: $OS_ERROR";
	foreach my $line (@lines) {
		print $TEXT_FILE $line;
	}
	close $TEXT_FILE;

	if (!$replacement_done_at) {
		print colored ['white on_red'], "WARNING: No replacement done on $fullpath for $misspelled -> $suggested_word\n";
	} else {
		print $progress_report;
	}
	return $replacement_done_at;
}

sub replace_text_content {
	my ($meta, $misspelled, $suggested_word) = @_;
	my $fullpath = $meta->{filename};
	return replace_first_occurrence($fullpath, $meta->{line_no}, $misspelled, $suggested_word);

}

sub report_on_text_replacement {
	my ($meta, $original_word, $suggested_word, $line_no) = @_;
	notify_action(
		  "'$original_word' -> '$suggested_word' in "
		. $meta->{filename}
		. ':'
		. $line_no
		)
		;
}

sub replace_in_en_US_sources {
	my ($original_word, $suggested_word, $po) = @_;
	my $success = 1;

	foreach my $source (Spelchek::get_source_meta($po->reference())) {
		if ($source->{type} eq 'DB') {
			my $line_no = get_po_line($po->msgid());
			my $sql_line_no_replaced
				= replace_en_US_db_content(
						$source->{meta},
						$line_no,
						$original_word,
						$suggested_word
					);
			if ($sql_line_no_replaced) {
				$statistics_for
					->{replacements}
				->{"$original_word -> $suggested_word"} += 1;
				my $meta = {
					filename => $Spelchek::sql_file,
					line_no  => $sql_line_no_replaced,
				};
				report_on_text_replacement($meta,
						$original_word,
						$suggested_word,
						$sql_line_no_replaced
					);
			} else {
				$success = 0;
			}
		} elsif ($source->{type} eq 'FILE') {
			if (my $line_no = replace_text_content($source->{meta}, $original_word, $suggested_word)) {
				report_on_text_replacement($source->{meta}, $original_word, $suggested_word, $line_no);
			}
			else {
				$success = 0;
			}
		}
	}

	return $success;
}

sub replace_in_po_file {
	my ($original_word, $suggested_word, $po) = @_;

	my $success = 1;

	my $line_no = get_po_line($po->msgid(), 'for msgstr');
	my $meta = {
		filename => "lib/I18N/$LANGUAGE.po",
		line_no  => $line_no,
	};
	if (my $line_no = replace_text_content($meta, $original_word, $suggested_word)) {
		report_on_text_replacement($meta, $original_word, $suggested_word, $line_no);
		$success = 1;
	}
	else {
		$success = 0;
	}

	return $success;
}

sub sort_ignored_phrases {
	# This need to be sorted from longest to shortest so that the sorter
	# phrases do no get in the way of the longer one when we check for their
	# occurrence later.
	@IGNORED_PHRASES
		= reverse sort
			{ length $a <=> length $b }
			(keys %ignored_phrase_count_for);
}

sub action_handler_ignore_phrase {
	my ($speller, $misspelled, $po) = @_;

	if (length $GIVEN_TEXT == 0) {
		print colored ['white on_red'], "Usage: P <phrase>\n";

		return 0;
	}
	open my $IGNORED_PHRASES, '>>', $IGNORED_PHRASES_FILE
		or die "Could no open $IGNORED_PHRASES_FILE: $OS_ERROR";
	print $IGNORED_PHRASES $GIVEN_TEXT . "\n";
	close $IGNORED_PHRASES;
	if (! defined $ignored_phrase_count_for{$GIVEN_TEXT}) {
		# Set it to 1 so that it won't show up as unmatched.
		# Trust the user that the phrase happens at least once.
		$ignored_phrase_count_for{$GIVEN_TEXT} = 1;
		sort_ignored_phrases();
	}
	notify_action("Added '$GIVEN_TEXT' to $IGNORED_PHRASES_FILE");
}

sub action_handler_replace_with_given_text {
	my ($speller, $misspelled, $po) = @_;

	if (length $GIVEN_TEXT == 0) {
		print colored ['white on_red'], "Usage: r newword\n";

		return 0;
	}

	my $suggested_word = $GIVEN_TEXT;
	$speller->add_to_session($suggested_word);

	my $success = action_handler_replace_with_suggested($misspelled, $suggested_word, $po);

	return $success;
}

sub action_handler_replace_with_suggested {
	my ($original_word, $suggested_word, $po)= @_;
	my $success;

	if ($LANGUAGE eq 'en_US') {
		# Replace in the original source files where c.loc is done
		$success = replace_in_en_US_sources($original_word, $suggested_word, $po);
	}
	else {
		$success = replace_in_po_file($original_word, $suggested_word, $po);
		if ($success) {
			my $msgstr = $po->msgstr();
			$msgstr = replace_misspelling($original_word, $suggested_word, $msgstr);
			$po->msgstr($msgstr);
		}
	}

	if ($success) {
		$statistics_for
			->{replacements}
			->{"$original_word -> $suggested_word"} += 1;
	}

	return $success;
}

sub action_handler_replace_all {
	my ($speller, $misspelled, $po) = @_;

	print "Enter empty text to cancel.\n";
	print "Replace all '$misspelled' with: ";
	my $text = <STDIN>;
	chomp $text;
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;

	return 0 if (length $text == 0);

	$replace_all{$misspelled} = $text;
	$speller->add_to_session($text);

	return action_handler_replace_with_suggested($misspelled, $text, $po);
}

sub action_handler_ignore_once {
	my ($speller, $misspelled, $po) = @_;
	notify_action("[$misspelled] ignored once.");
	if (! defined $statistics_for->{ignored_word}->{$misspelled}) {
		$statistics_for->{ignored_word_count} += 1;
	}
	$statistics_for->{ignored_word}->{$misspelled} += 1;

	return 1;
}

sub show_msgid_and_msgstr {
	my ($po, $word) = @_;
	print colored ['black on_green'], " msgid";
	print ' ';
	print $po->msgid();
	print "\n";
	print colored ['black on_green'], "msgstr";
	print ' ';
	print highlight($MISSPELLED_COLOR, $word, $po->msgstr());
	print "\n";
}

sub action_handler_external_command {
	my ($cmd, $misspelled, $po) = @_;

	my $references = join_references($po->reference());
	notify_action("Running external command [$cmd]");
	$cmd =~ s/%{references}/$references/g;
	$cmd =~ s/%{wrongword}/$misspelled/g;
	debug("External command is [$cmd]\n");

	my $success = Spelchek::run_cmd($cmd);

	return $success;
}

sub handle_unknown_word {
	my ($speller, $misspelled, $po, $original_word) = @_;

	$statistics_for->{incorrect_word_count} += 1;
	$statistics_for->{misspelled_word}->{$misspelled} += 1;

	my $success = 1;

	return $success if $opt_summary_only;

	print "\n";

	debug( color('yellow') . " ORIG: " . $current_msgstr_stripped . color('reset') . "\n");

	debug( color('green') . "CLEAN: " . $current_msgstr_cleaned . color('reset') . "\n" );
	debug( color('white on_red')   . "REMOVED: " . $punctuations_removed . color('reset') . "\n")
		if (length $punctuations_removed);
	debug( color('white on_red')   . "REMOVED: " . $digits_removed . color('reset') . "\n")
		if (length $digits_removed);
	debug( color('white on_red')   . "REMOVED: " . $dashes_and_quotes_removed . color('reset') . "\n")
		if (length $dashes_and_quotes_removed);
	if ($misspelled =~ /-/) {
		print_header('UNKNOWN COMPOUND WORD');
	}
	else {
		print_header('UNKNOWN WORD');
	}

	# print colored [$MISSPELLED_COLOR], "$misspelled [$original_word]";

	# print colored [$MISSPELLED_COLOR], "$misspelled";
	# print "\n";

	# if ($misspelled ne $original_word) {
	#  	debug "ORIGINAL WORD: '$original_word'\n";
	# }
	if ($original_word =~ /&[a-z]+;/) {
		print " (original word: '";
		print colored [$MISSPELLED_COLOR], $original_word;
		print "')\n";
	}

	if ($LANGUAGE eq 'en_US') {
		if ($original_word =~ /&[a-z]+;/) {
			show_sources($original_word, $po);
		} else {
			show_sources($misspelled, $po);
		}
	} else {
		if ($original_word =~ /&[a-z]+;/) {
			# The &[a-z]+; part may have been eaten by our html_stripper, Use
			# $original_word for searching
			show_msgid_and_msgstr($po, $original_word);
		} else {
			show_msgid_and_msgstr($po, $misspelled);
		}
	}

	my @suggestions = $speller->suggest($misspelled);
	if (scalar @suggestions > $MAX_SUGGEST) {
		@suggestions = @suggestions[0 .. ($MAX_SUGGEST - 1)];
	}
	my $suggested_for = print_suggestions(@suggestions);

	print_header('ACTIONS');
	my $action = get_action();

	$success = 0;

	if (defined $suggested_for->{$action}) {
		my $suggested_word = $suggested_for->{$action};
		$speller->add_to_session($suggested_word);
		$success = action_handler_replace_with_suggested($original_word, $suggested_word, $po);
	}
	elsif (ref $action->{handler} eq 'CODE') {
		$success = $action->{handler}->($speller, $misspelled, $po, $original_word);
	}
	elsif ($action->{external}) {
		my $external_command = $action->{handler};
		$success = action_handler_external_command($external_command, $misspelled, $po);
		if ($success) {
			$success = $action->{'continue'} || 1;
		}
	}
	else {
		print colored ['white on_blue'], "TODO: Action not implemented: '", $action->{text}, "'\n";
	}

	return $success;
}

sub is_known_abbreviation {
	my $word = shift;
	return $internal_dict_has{$word};
}

sub is_in_internal_dict {
	my $word = shift;
	my $lowercase = lowercase($word);
	return $internal_dict_has{$lowercase};
}

sub check_spelling {
	my ($speller, $po, $original_word, @words) = @_;
	my $incorrect_word_count = 0;

	foreach my $w (@words) {
		if (defined $statistics_for->{ignored_word}->{$w}) {
			$statistics_for->{ignored_word}->{$w} += 1;
		}
		if (is_known_abbreviation($w)) {
			debug("Found in abbreviation: $w\n", 2);
			next;
		}
		if (is_in_internal_dict($w)) {
			debug("Found in internal (local+global) dict: $w\n", 2);
			next;
		}
		next if (! length $w);
		debug ("Checking [$w]\n", 3);

		if (defined $replace_all{$w}) {
			action_handler_replace_with_suggested($w, $replace_all{$w}, $po);
			return;
		}

		if (! $speller->check($w)) {
			$incorrect_word_count += 1;

			my $c = 0;
			while ( ! handle_unknown_word($speller, $w, $po, $original_word) ) {
				if ($c > 10) {
					print colored ['black on_yellow'],
						  "The 'continue' action is hardcoded to stop at 10 iteractions\n.";
					print "\n";
					# don't repeat forever, just in case.
					last;
				}
				$c += 1;
			}
		}
	}
	return $incorrect_word_count;
}

sub load_local_dict {
	my ($speller, $dict_file, $case_sensitive, $add_to_suggestions) = @_;

	$case_sensitive ||= 0;
	$add_to_suggestions ||= 1;

	return if ( ! -f $dict_file );

	open my $LOCAL_DICT, '<', $dict_file
		or die "Could not open $dict_file: $OS_ERROR";

	while (my $word = <$LOCAL_DICT>) {
		next if ( $word =~ /^\s*#/ );
		chomp $word;
		$word =~ s/\\#/#/g; # Allow escaped # - '\#'
		if (! $case_sensitive) {
			$word = lowercase($word);
		}
		$internal_dict_has{$word} = 1;
		if ($add_to_suggestions) {
			$speller->add_to_session($word);
		}
	}
}

sub load_ignored_phrases {
	if ( ! -f $IGNORED_PHRASES_FILE ) {
		return;
	}

	open my $IGNORED_PHRASES, '<', $IGNORED_PHRASES_FILE
		or die "Could not open $IGNORED_PHRASES_FILE: $OS_ERROR";
	while (my $line = <$IGNORED_PHRASES>) {
		chomp $line;
		$ignored_phrase_count_for{$line} = 0;
	}
	close $IGNORED_PHRASES;
	sort_ignored_phrases();
}

sub remove_beginning_and_ending {
	my ($to_remove, $text, $literal) = @_;
	$literal ||= 1;
	if ($literal) {
		$text =~ s/^\Q$to_remove\E+//;
		$text =~ s/\Q$to_remove\E+$//;
	} else {
		$text =~ s/^$to_remove+//;
		$text =~ s/$to_remove+$//;
	}
	return $text;
}

sub remove_punctuations_but_not {
	my ($msgstr, $but_not) = @_;

	my $removed = '';
	$msgstr =~ s/(([$but_not])|([[:punct:]]))/$removed .= $3 if defined $3;$2 || ' ';/ge;

	return ($msgstr, $removed);
}

sub remove_punctuations_but_not_dash_and_quote {
	my ($msgstr) = @_;

	my $removed = '';
	$msgstr =~ s/(([-'])|([[:punct:]]))/$removed .= $3 if defined $3;$2 || ' ';/ge;

	return ($msgstr, $removed);
}

sub remove_digits {
	my ($msgstr) = @_;

	my $removed = '';
	$msgstr =~ s/([[:digit:]])/$removed .= $1 if defined $1;' ';/ge;

	return ($msgstr, $removed);
}

sub remove_beginning_and_ending_dashes_and_quotes {
	my ($msgstr) = @_;

	my $removed = '';
	$msgstr =~ s/\s([-'])/$removed .= $1 if defined $1;' ';/ge;
	$msgstr =~ s/([-'])\s/$removed .= $1 if defined $1;' ';/ge;
	$msgstr =~ s/^[-']/ /;
	$msgstr =~ s/[-']$/ /;

	return ($msgstr, $removed);
}

my $html_stripper = HTML::Strip->new(); # yummy!
$html_stripper->set_decode_entities(0);

sub remove_insignificant_characters {
	my ($msgstr) = @_;

	# Remove beginning and ending quotes
	$msgstr =~ s/^"//;
	$msgstr =~ s/"$//;

	# Remove HTML tags, retain HTML entities (&[a-z]+;)
	$msgstr = $html_stripper->parse($msgstr);
	$html_stripper->eof();
	# Remove undecoded html entities
	$msgstr =~ s/&[a-z]+;/ /g;

	# Remove escaped newlines, tabs
	$msgstr =~ s/\\n/\n/gs;
	$msgstr =~ s/\\t/ /gs;

	$current_msgstr_stripped = $msgstr;


	# ($msgstr, $punctuations_removed) = remove_punctuations_but_not_dash_and_quote($msgstr);
	if ($LANGUAGE eq 'en_US') {
		# This is so that we can catch mistakes like
		# 'State-of-art', which should be 'State-of-the-art'
		($msgstr, $punctuations_removed) = remove_punctuations_but_not($msgstr, "-'");
	}
	else {
		($msgstr, $punctuations_removed) = remove_punctuations_but_not($msgstr, "'");
	}
	($msgstr, $digits_removed)       = remove_digits($msgstr);
	($msgstr, $dashes_and_quotes_removed) = remove_beginning_and_ending_dashes_and_quotes($msgstr);

	$current_msgstr_cleaned = $msgstr;

	return $msgstr;
}

sub remove_ignored_phrases {
	my ($msgstr) = @_;

	foreach my $phrase (@IGNORED_PHRASES) {
		my $nsubs = $msgstr =~ s/\b($phrase)\b/' ' x length($1)/gmse;
		$ignored_phrase_count_for{$phrase} += $nsubs;
	}

	return $msgstr;
}

sub spelchek {
	my ($lang, $messages_aref) = @_;

	my $speller = Text::Aspell->new or die "Could not create speller\n";

	$speller->set_option('lang',$lang);
	load_local_dict($speller, $LOCAL_DICT_FILE);
	my $case_sensitive = 1;
	load_local_dict($speller, $COMMON_DICT_FILE, $case_sensitive);

	$case_sensitive = 0;
	load_local_dict($speller,
						$ABBREVIATION_FILE,
						$case_sensitive,
						0, # don't add to suggestion
				);

	load_ignored_phrases();

	if (defined $PERSONAL_DICT_FILE) {
		load_local_dict($speller,
							$PERSONAL_DICT_FILE_MANGLED,
							1, # case sensitive
							0, # don't add to suggestion
					);
	}

	my $count = -1;
	for my $po (@$messages_aref) {
		$count += 1;
		next if ($po->fuzzy());
		next if ($po->obsolete());

		my $msgid = $po->msgid();
		# Skip po header
		next if $msgid eq '""';

		my $msgstr = $po->msgstr();
		$pristine_msgstr = $msgstr;

		$msgstr = remove_ignored_phrases($msgstr);

		$msgstr = remove_insignificant_characters($msgstr);

		# squash whitespaces
		$msgstr =~ s/\s+/ /g;
		next if ($msgstr eq ' ');

		my @words = split(/ /, $msgstr);

		for my $phrase (@words) {
			if ($phrase =~ /-/) {
				my @individual_words = split(/-/, $phrase);
				$statistics_for ->{total_word_count} += scalar @individual_words;
				check_spelling($speller, $po, $phrase, @individual_words);
			}
			else {
				$statistics_for->{total_word_count} += 1;
			}
			check_spelling($speller, $po, $phrase, $phrase);
		}
	}
}

sub installed {
	my $prog = shift;
	my $bin = `which $prog`;
	chomp $bin;
	return length $bin;
}

sub load_action_list {
	@action_list = (
			i => { text => 'Ignore once',
					handler => \&action_handler_ignore_once },
			I => { text => 'Ignore all',
					handler => \&action_handler_ignore_all },
			a => { text => "Add to $LOCAL_DICT_FILE",
					handler => \&action_handler_add_to_lang_dict },
			A => { text => "Add to $COMMON_DICT_FILE",
					handler => \&action_handler_add_to_common_dict },
			b => { text => "Add to $ABBREVIATION_FILE (case!)",
					handler => \&action_handler_add_to_abbreviation_dict },
			r => { text => 'Replace <with this text>',
					handler => \&action_handler_replace_with_given_text },
			R => { text => 'Replace all',
					handler => \&action_handler_replace_all },
			e => { text => 'Edit',
					handler => \&action_handler_edit_source },
			P => { text => "Add <phrase> to $IGNORED_PHRASES_FILE",
					handler => \&action_handler_ignore_phrase },
			q => { text => 'Exit',
					handler => \&action_handler_exit },
		);

	if (defined $conf{personal_dictionary}) {
		push @action_list, (
			p => { text => "Add to $PERSONAL_DICT_FILE",
					handler => \&action_handler_add_to_personal_dict },
		)
	}

	my %action_for = @action_list;
	foreach my $external_command (@external_commands) {
		my $shortcut = $external_command->{shortcut};
		if (defined $action_for{$shortcut}) {
			my $description = $action_for{$shortcut}->{text};
			print colored ['red'],"WARNING: The default shortcut '$shortcut' "
				. "for '$description' is overridden in $spellcheckrc with '"
				. $external_command->{description}
				. "'\n";
		}
		push @action_list, (
				$external_command->{shortcut}
					=> {
						text => $external_command->{description},
						handler => $external_command->{command},
						external => 1,
					},
			);
	}

	%action_for = @action_list;

	foreach my $key (keys %action_for) {
		my $len = length ($action_for{$key}->{text});
		if ($LONGEST_COMMAND_LENGTH < $len) {
			$LONGEST_COMMAND_LENGTH = $len;
		}
	}
}

sub confirm_en_US_po_file_is_uptodate_or_exit {
	print_header(' REMINDER ');
	print "For en_US, the correct operation of $me is critically
dependent on the up-to-date status of $LANGUAGE.po. If the $LANGUAGE.po is not
up-to-date, the spelling corrections is not guaranteed to work correctly.\n";

	return ; # And skip the following:

	my $answer = '';
	my $acceptable_answer = 'cgq';
	while ($answer !~ /^[$acceptable_answer]$/i) {
		if ($answer ne '') {
			print "\n\nSorry, my response is limited. Please specify one of c/g/q.";
		}
		print "

  c) The $LANGUAGE.po is already up to date, [c]ontinue.
  g) Automatically run 'make [g]ettext LANGUAGE=$LANGUAGE' to update $LANGUAGE.po.
  q) [Q]uit.

Your choice: ";

		$answer = read_one_char();
	}

	print "$answer\n";

	$answer = lc ($answer);

	if ($answer eq 'c') {
		return;
	}
	if ($answer eq 'g') {
		system("make gettext LANGUAGE=$LANGUAGE");
		print "Done running 'make gettext LANGUAGE=$LANGUAGE'\n";
		return;
	}
	exit 0;
}

sub bootstrap_or_exit {
	my %need = (
			# We no longer need ack, bye bye ack
			# ack => 'sudo apt-get install ack-grep',
	);

	my $all_good = 1;
	foreach my $app (keys %need) {
		if (! installed($app)) {
			printf "Please install %s:\n %s\n",$app, $need{$app};
			$all_good = 0;
		}
	}
	if (! $all_good) {
		exit 0;
	}

	if ($LANGUAGE =~ /help/) {
		print_usage();
		exit 0;
	}

	my ($wchar, $hchar, $wpixels, $hpixels) = GetTerminalSize();
	if (defined $wchar) {
		$TERMINAL_WIDTH = $wchar;
	}

	print_header(' REMINDER ');
	print "Due knot trussed yore spell chequer two fined awl miss steaks.\n";

	if ($LANGUAGE eq 'en_US' && ! $opt_summary_only) {
		confirm_en_US_po_file_is_uptodate_or_exit();
	}
}

sub cleanup {
	action_handler_exit();
}

sub thing_doer {
	my $language = shift;

	my $po_file = "$language.po";
	if ( ! -e $po_file ) {
		if ($language eq 'en_US') {
			print "For en_US please generate the en_US.po file by running 'make gettext LANGUAGE=en_US'\n";
			exit 1;
		}
		elsif ($language eq 'en_GB') {
			print "At the moment en_GB is not maintained by hand, and it is\n"
				. "generated automatically from en_US.po. Any spelling mistake\n"
				. "in en_US.po will be carried over to en_GB.mo.\n"
				;
			exit 0;
		}
		else {
			print "$language.po does not exists. Spell check aborted.\n";
			exit 1;
		}
	}

	my $messages_aref = Locale::PO->load_file_asarray($po_file);

	spelchek($language, $messages_aref);
}

bootstrap_or_exit();

load_action_list();

thing_doer($LANGUAGE);
cleanup();

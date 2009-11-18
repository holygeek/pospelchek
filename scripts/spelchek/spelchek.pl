#!/usr/bin/perl -w
use strict;
use warnings;
use Data::Dumper;
use Config::General;
use Term::ANSIColor;
use Config::General;
use Locale::PO;
use Regexp::Common;

# Config entries (~/.spellcheckrc)
#
# Entry: text_editor
# Vars : %{filename} %{line_no}  %{wrongword}

if (! defined $ARGV[0] ) {
	print "Usage: " . __FILE__ . " <language>\n";
	print "Example: " . __FILE__ . " en_US\n";
	exit 1;
}

my $default_text_editor = "vi %{filename} +%{line} -c 'set hlsearch' -c 'normal /%{wrongword}'";
sub print_usage {
	my $default_text_e = $default_text_editor;
	$default_text_e =~ s//^M/;

print "
CUSTOMIZATION
=============
spelchek.pl can be customized via ~/.spellcheckrc.
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
  
  2. <external_command>
          shortcut = <a single letter>
          description = Descriptive text
          command = command arguments ...
          continue = <0 or 1>
     </external_command>
  
     More than one <external_command> entries are accepted.
     The 'command' entries in each <external_command> entries will be mangled
     using the following patterns:
  
          PATTERN         REPLACEMENT
        %{references}   The reference for the msgid in the po file.
                        If there are more than one references, they will be
                        joined with the comma character. Commas in the
                        reference itself will be escaped with backslash (\,).
        %{wrongword}    The misspelled word
  
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
  
     If defined, spellcheck.pl will also use the specified personal_dictionary.

To begin spellchecking:
=======================

    \$ make spellcheck LANGUAGE=en_US

	or

    \$ make spellcheck LANGUAGE=ms_MY

Quick guide on choosing which dictionary to save unknown word to:
=================================================================

  1. Add to ./dict/\$LANG.abbr.txt if it is a valid abbreviation. spellcheck.pl
     will honor the case sensitivity of the abbreviation: If you add 'BMI' into
     it, 'BMI' will be considered as a correct word while 'bmi' is not.
   
  2. Add to ./dict/\$LANG.abbr.txt if it is a valid word for the language.
   
  3. Add to ./dict/common.txt if it is a valid word for all languages. Examples of
     words that are valid for all languages are \$FULLNAME\$, VAR_NAME, etc.

  4. If it's none of the above, then put it into your personal_dictionary (see
     CUSTOMIZATION above).

Have fun spellchecking!
";
}

if ($ARGV[0] eq 'ALL_SUPPORTED_LANGUAGES') {
	print_usage();
	exit 0;
}
my $LANGUAGE = $ARGV[0];
my $LOCAL_DICT_FILE = "./dict/$LANGUAGE.txt";
my $ABBREVIATION_FILE = "./dict/$LANGUAGE.abbr.txt";
my $PERSONAL_DICT_FILE = undef;
my $COMMON_DICT_FILE = './dict/common.txt';
my $MISSPELLED_COLOR = 'white on_red'; # Same as ack's highlighting
my $CORRECTED_COLOR  = 'black on_green';
my %internal_dict_has;
my %statistics;
my $debug = 0;

my %conf;
my @external_commands;
my @action_list;
my $spellcheckrc = $ENV{HOME} . "/.spellcheckrc";

sub lowercase {
	my $text = shift;
	$text =~ tr/A-Z/a-z/;
	return $text;
}

sub load_spellcheckrc {
	if ( -f $spellcheckrc ) {
		my $c = new Config::General($spellcheckrc);
		%conf = $c->getall;

		my $external_command_entry = $conf{external_command};
		if (ref $external_command_entry eq 'ARRAY') {
			@external_commands = @{$external_command_entry};
		} else {
			@external_commands = ($external_command_entry);
		}
		if (defined $conf{personal_dictionary}) {
			$PERSONAL_DICT_FILE = $conf{personal_dictionary};
			$PERSONAL_DICT_FILE =~ s/^~/$ENV{HOME}/;
		}
	}
}

sub set_default_options {
	if (! defined $conf{dict_dir}) {
		$conf{dict_dir} = '.dict';
	}
	if (! defined $conf{text_editor}) {
		$conf{text_editor} = $default_text_editor;
	}
}

use File::Slurp qw/slurp/;

use Carp qw/croak/;
use English;
use Text::Aspell;
use HTML::Strip;

sub debug {
	my ($text, $level) = @_;
	$level ||= 1;
	if ($debug >= $level) {
		print colored ['yellow on_black'], "DEBUG: " . $text;
	}
}

sub notify_action {
	my ($text) = @_;
	print colored ['green'],$text;
	print "\n";
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
}

sub todo {
	my ($text) = @_;
	print colored ['black on_green'],"TODO: $text\n";
}

sub edit_db {
	my $meta = shift;
	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};
	todo("Edit DB TABLE $table PRIMARY KEY $primary_key_column = $primary_key_value COLUMN $column_name");
}

sub edit_file {
	my ($file_path, $line_no, $misspelled) = @_;

	if (defined $conf{text_editor}) {
		my $cmd = $conf{text_editor};
		$cmd =~ s/%{filename}/$file_path/g;
		$cmd =~ s/%{line}/$line_no/g;
		$misspelled =~ s/'/\\'/g;
		$cmd =~ s/%{wrongword}/$misspelled/g;
		notify_action("Editing $file_path");
		system($cmd);
	} else {
		print "No editor defined.\n";
	}
}

sub edit_source {
	my ($po, $misspelled) = @_;

	foreach my $source (get_source_meta($po)) {
		if ($source->{type} eq 'DB') {
			edit_db($source->{meta}, $misspelled);
		} elsif ($source->{type} eq 'FILE') {
			my $fullpath = $source->{meta}->{filename};
			edit_file($fullpath, $source->{meta}->{line_no}, $misspelled);
		}
	}
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
	edit_file("$LANGUAGE.po", $line_no, $misspelled);
}

sub action_handler_edit_source {
	my ($speller, $misspelled, $po, $original_word) = @_;
	if ($LANGUAGE eq 'en_US') {
		edit_source($po, $misspelled);
	} else {
		edit_po_file($po, $original_word);
	}
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

	my $dict_file = $PERSONAL_DICT_FILE;

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

sub show_statistics {
	print "Replacement summary:\n";
	my $c = 0;
	foreach my $key (sort keys %statistics) {
		my $frequency = $statistics{$key};
		$c += $frequency;
		printf "  $key: $frequency time";
		if ($frequency > 1) {
			print "s";
		}
		print ".\n";
	}
	print "Total $c replacements.\n"; 
	print "(Excludes edits)\n";
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
		sort_and_remove_duplicate($PERSONAL_DICT_FILE, $case_sensitive);
	}
	show_statistics();
	exit 0;
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

sub get_action {
	my %action_for =  @action_list;

	my $acceptable_actions = join ('|', keys %action_for);

	my $action = '';
	while ($action !~ /^($acceptable_actions)$/) {
		my $c = 0;
		for my $i (0 .. scalar @action_list / 2 - 1) {
			my $key = $action_list[$i * 2];
			my $text = $action_list[$i * 2 + 1]->{text};
			printf "%2s) %-40s", $key, $text;
			$c += 1;
			if ($c % 2 == 0) {
				print "\n";
			}
		}
		if ($c % 2) {
			print "\n";
		}
		print "Action: ";
		$action = <STDIN>;
		chomp $action;
		if (length $action == 0) {
			$action = 'i';
		}

		if ($action =~ /^[0-9]+$/) {
			return $action;
		}
	}

	return $action_for{$action};
}

sub print_header {
	my $text = shift;
	my $len = length($text);
	print '--',$text,'-' x (80 - $len),"\n";
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
		if (defined $candidates[$i + $nrows]) {
			$right = " $c) " . $candidates[$i + $nrows];
			$suggested_for{$c} = $candidates[$i + $nrows];
		}
		printf "%-49s%-49s\n", $left, $right;
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
	$text =~ s/([^[:alpha:]])\Q$misspelled\E([^[:alpha:]])/"$1".color($color).$misspelled.color('reset')."$2"/sge;
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
	$misspelled =~ s/ /./g;

	my $line_count_after_match = 0;

	my $text_of_last_match;
	my $line_no_of_last_match = 0;
	while (my $line = <$IN>) {
		$c += 1;

		if ($line =~ /[^[:alpha:]]\Q$misspelled\E[^[:alpha:]]/) {
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

my $database_reference = "lib/I18N/db/([A-Za-z]+).db:([a-z_]+)=([0-9]+):([a-z_]+)";
sub get_source_meta {
	my $po = shift;
	my $reference = $po->reference();
	# $reference look like this:
	#   www/javascript/context_help.js:464
	#   lib/I18N/db/QuestionList.db:question_id=109:question
	my @source_meta;
	foreach (split(/\n/, $reference)) {
		if ( my (
					$table,
					$primary_key_column,
					$primary_key_value,
					$column_name
				) = $_ =~ m#$database_reference#
		) {
			push @source_meta, 
					{
						type => 'DB',
						meta => {
							table => $table,
							primary_key_column => $primary_key_column,
							primary_key_value => $primary_key_value,
							column_name => $column_name,
						}
					};
		}
		else { 
			my ($filename, $line_no) = split /:/;
			push @source_meta, 
					{
						type => 'FILE',
						meta => {
							filename => $filename,
							line_no  => $line_no,
						}
					};
		}
	}
	return @source_meta;
}

sub show_db_content {
	my $meta = shift;
	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};
	print "Database entry: TABLE '$table' PRIMARY KEY '$primary_key_column' = '$primary_key_value' COLUMN '$column_name'\n";
}

sub show_sources {
	my ($misspelled, $po) = @_;
	
	# print "Showing sources fo \'$misspelled\'\n";
	foreach my $source (get_source_meta($po)) {
		if ($source->{type} eq 'DB') {
			show_db_content($source->{meta});
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

sub replace_db_content {
	my ($meta, $misspelled, $suggested_word) = @_;
	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};
	print colored ['black on_yellow'],
		  "TODO Replace content $misspelled with $suggested_word in\n";
	print colored ['black on_yellow'],
		  "TABLE $table PRIMARY KEY $primary_key_column = $primary_key_value COLUMN $column_name\n";
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
		if ($lines[$c] =~ /[^[:alpha:]]$misspelled[^[:alpha:]]/) {
			$lines[$c] =~ s/([^[:alpha:]])$misspelled([^[:alpha:]])/$1$suggested_word$2/;
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

sub action_handler_replace_with_suggested {
	my ($original_word, $suggested_word, $po)= @_;

	if ($LANGUAGE eq 'en_US') {
		# Replace in the original source files where c.loc is done
		foreach my $source (get_source_meta($po)) {
			if ($source->{type} eq 'DB') {
				replace_db_content($source->{meta}, $original_word, $suggested_word);
			} elsif ($source->{type} eq 'FILE') {
				if (my $line_no = replace_text_content($source->{meta}, $original_word, $suggested_word)) {
					$statistics{"$original_word -> $suggested_word"} += 1;
					report_on_text_replacement($source->{meta}, $original_word, $suggested_word, $line_no);
				}
			}
		}
	}
	else {
		# Replace in $LANGUAGE.po file
		my $line_no = get_po_line($po->msgid(), 'for msgstr');
		my $meta = {
				filename => "lib/I18N/$LANGUAGE.po",
				line_no  => $line_no,
			};
		if (my $line_no = replace_text_content($meta, $original_word, $suggested_word)) {
			report_on_text_replacement($meta, $original_word, $suggested_word, $line_no);
		}
	}
}

sub action_handler_ignore_once {
	my ($speller, $misspelled, $po) = @_;
	notify_action("[$misspelled] ignored once.");
}

sub show_msgid_and_msgstr {
	my ($po, $word) = @_;
	print colored ['black on_green'], "msgid";
	print ' ';
	print $po->msgid();
	print "\n";
	# debug "ACK PATTERN is '$word'\n";
	print colored ['black on_green'], "msgstr";
	print ' ';
	open my $ACK, 
		 "|ACK_COLOR_MATCH='$MISSPELLED_COLOR' "
		 . "ack -1 --literal --word-regexp --color --passthru '$word'"
		or die "Could not run ack: $OS_ERROR";
	print $ACK $po->msgstr();
	close $ACK;
	print "\n";
}

sub action_handler_external_command {
	my ($cmd, $misspelled, $po) = @_;

	my $references = $po->reference();
	$references =~ s/,/\\,/gxms;

	$references = join(',', split(/\n/, $references));
	notify_action("Running external command [$cmd]");
	$cmd =~ s/%{references}/$references/g;
	$cmd =~ s/%{wrongword}/$misspelled/g;
	debug("External command is [$cmd]\n");
	system($cmd);
}

sub handle_unknown_word {
	my ($speller, $misspelled, $po, $original_word) = @_;

	my $check_again = 0;

	print "\n";
	if ($misspelled =~ /-/) {
		print_header('UNKNOWN COMPOUND WORD');
	}
	else {
		print_header('UNKNOWN WORD');
	}

	# print colored [$MISSPELLED_COLOR], "$misspelled [$original_word]";
	print colored [$MISSPELLED_COLOR], "$misspelled";
	print "\n";
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

	my $suggested_for = print_suggestions($speller->suggest($misspelled));

	print_header('ACTIONS');
	my $action = get_action();

	if (defined $suggested_for->{$action}) {
		my $suggested_word = $suggested_for->{$action};
		action_handler_replace_with_suggested($original_word, $suggested_word, $po);
	}
	elsif (ref $action->{handler} eq 'CODE') {
		$action->{handler}->($speller, $misspelled, $po, $original_word);
	}
	elsif ($action->{external}) {
		my $external_command = $action->{handler};
		action_handler_external_command($external_command, $misspelled, $po);
		$check_again = $action->{'continue'} || 1;
	}
	else {
		print colored ['white on_blue'], "TODO: Action not implemented: '", $action->{text}, "'\n";
	}
	return $check_again;
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
	my $valid_phrase = 1;
	#my $look_like_number = "[+%\$-]{0,1}$RE{num}{real}%{0,1}";
	foreach my $w (@words) {
		# if (
		# 	   $w =~ /^($look_like_number)(-$look_like_number)*$/
		#    ) {
		# 	# Skip numbers, percentage, and their ranges, variable placeholders (%1)
		# 	next;
		# }

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
		if (! $speller->check($w)) {
			$valid_phrase = 0;
			#my $need_further_check = 1;
			#if ($w =~ /^($RE{num}{real}|\d+)[-]{0,1}/) {
			#	my $no_number = $w;
			#	$no_number =~ s/^$RE{num}{real}//;
			#	$need_further_check =  ! $speller->check($no_number);
			#} elsif ($w =~ /$RE{num}{real}$/) {
			#	my $no_number = $w;
			#	$no_number =~ s/$RE{num}{real}$//;
			#	$need_further_check =  ! $speller->check($no_number);
			#}
			#next if (! $need_further_check );

			my $c = 0;
			while ( handle_unknown_word($speller, $w, $po, $original_word) ) {
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
	return $valid_phrase;
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

sub spelchek {
	my ($lang, $messages_aref) = @_; 

	my $speller = Text::Aspell->new or die "Could not create speller\n";

	$speller->set_option('lang',$lang);
	load_local_dict($speller, $LOCAL_DICT_FILE);
	load_local_dict($speller, $COMMON_DICT_FILE);

	my $case_sensitive = 0;
	load_local_dict($speller,
						$ABBREVIATION_FILE,
						$case_sensitive,
						0, # case insensitive
						0, # don't add to suggestion
				);
	if (defined $PERSONAL_DICT_FILE) {
		load_local_dict($speller,
							$PERSONAL_DICT_FILE,
							1, # case sensitive
							0, # don't add to suggestion
					);
	}


	my $html_stripper = HTML::Strip->new(); # yummy!
	$html_stripper->set_decode_entities(0);
	
	# %1, $1.5
	my $look_like_number = "[+%\$-]{0,1}$RE{num}{real}\%{0,1}";

	print "Spellchecking $lang.\n\n";
	for my $po (@$messages_aref) {
		next if ($po->fuzzy());
		# TODO: next if ($po->obsolete());
		# TODO: HAVE to upgrade Locale::PO to 0.21

		my $msgid = $po->msgid();
		my $msgstr = $po->msgstr();

		$msgid =~ s/^"//;
		$msgid =~ s/"$//;
		# Skip po header
		next if (length $msgid == 0);
		$msgstr =~ s/^"//;
		$msgstr =~ s/"$//;

		# Remove newlines and tab escape sequences
		$msgstr =~ s/\\n/\n/gs;
		$msgstr =~ s/\\t/ /gs;
		$msgstr =~ s/\\"/ /gs;

		# Unescape backslashes
		#$msgstr =~ s/\\\\/\\/gs;

		# squash whitespaces
		$msgstr =~ s/\s+/ /g;

		$msgstr = $html_stripper->parse($msgstr);

		$msgstr =~ s/\b($look_like_number)(-$look_like_number)*\b/ /g;

		$msgstr =~ s/ ($look_like_number)/' ' x length($1)/ge;
		$msgstr =~ s/($look_like_number) /' ' x length($1)/ge;

		my @words = split(/\s/, $msgstr);

		for my $phrase (@words) {
			# Remove non-word characters
			# my $phrase = $html_stripper->parse($word);

			# Remove html entities
			$phrase =~ s/&[a-z]+;//g;

			$phrase = remove_beginning_and_ending('.', $phrase);
			$phrase = remove_beginning_and_ending('"', $phrase);
			$phrase = remove_beginning_and_ending("'", $phrase);
			$phrase = remove_beginning_and_ending('-', $phrase);
			$phrase = remove_beginning_and_ending('\d', $phrase, 0);

			# Remove punctuations
			$phrase =~ s/,/ /g;
			$phrase =~ s/[!,.()?=\/><;:]/ /g;

			# Remove variable substitution placeholders
			$phrase =~ s/([^\\]*)%[0-9]+/$1 /g;

			# Remove single-quotes in the middle
			$phrase =~ s/' / /g;
			$phrase =~ s/ '/ /g;

			$phrase =~ s/\s+/ /g;
			$phrase = remove_beginning_and_ending(' ', $phrase, 0);

			if ($phrase =~ /-/) {
				check_spelling($speller, $po, $phrase, split(/-/, $phrase));
			}
			check_spelling($speller, $po, $phrase, split(/\s+/, $phrase));
			$html_stripper->eof();
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
			i => { text => 'Ignore once (default)',
					handler => \&action_handler_ignore_once },
			I => { text => 'Ignore all',
					handler => \&action_handler_ignore_all },
			a => { text => "Add to $LOCAL_DICT_FILE",
					handler => \&action_handler_add_to_lang_dict },
			A => { text => "Add to $COMMON_DICT_FILE",
					handler => \&action_handler_add_to_common_dict },
			b => { text => "Add to $ABBREVIATION_FILE (case!)",
					handler => \&action_handler_add_to_abbreviation_dict },
			q => { text => 'Exit',
					handler => \&action_handler_exit },
			e => { text => 'Edit',
					handler => \&action_handler_edit_source },
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
}

sub bootstrap_or_exit {
	my %need = (
			ack => 'sudo apt-get install ack-grep',
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

	my $all_options = join (',', @ARGV);
	if (length $all_options) {
		my ($d) = $all_options =~ m/DEBUG=([0-9]+)/;
		$debug = $d;
	}
	if ($LANGUAGE =~ /help/) {
		print_usage();
		exit 0;
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
		else {
			print "$language.po does not exists. Spell check aborted.\n";
			exit 1;
		}
	}
	
	my $messages_aref = Locale::PO->load_file_asarray($po_file);

	spelchek($language, $messages_aref);
}

bootstrap_or_exit();

load_spellcheckrc();
load_action_list();

set_default_options();
thing_doer($LANGUAGE);
cleanup();

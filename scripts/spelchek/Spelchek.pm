package Spelchek;
use Config::General;
use Term::ANSIColor;

our $spellcheckrc = $ENV{HOME} . "/.spellcheckrc";
my $default_text_editor
	= "vi %{filename} +%{line} -c 'set hlsearch' -c 'normal /%{wrongword}'";
our $sql_file = 'datadump.sql';
our $spellcheck_fix_sql_file = 'spellcheck_fix.sql';

#my $database_reference
#	= "lib/I18N/db/([A-Za-z]+).db:([a-z_]+)=([0-9]+):([a-z_]+)";

sub todo {
	my ($text) = @_;
	print colored ['black on_green'],"TODO: $text\n";
}

sub run_cmd {
	my $cmd = shift;

	my $success = 1;

	system($cmd);
	
	if ($? == -1) {
		print "Failed to execute: $!\n";
		$success = 0;
	}
	elsif ($? & 127) {
		printf "child died with signal %d, %s coredump\n",
			   ($? & 127), ($? & 128) ? 'with' : 'without';
		$success = 0;
	}

	return $success;
}

sub get_config {
	if ( ! -f $spellcheckrc ) {
		return {};
	}

	my $c = new Config::General($spellcheckrc);
	my %conf = $c->getall;

	$conf{text_editor} ||= $default_text_editor;
	$conf{po_reference_editor}
		||=   "po_reference_editor.pl "
			. "%{wrongword} %{po_line} %{references}";

	return \%conf;
}

sub get_sql_line_for {
	my $meta = shift;

	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};

	open my $SQL, '<', $sql_file
		or die "Could not open $sql_file";

	my $table_creation = 'CREATE TABLE IF NOT EXISTS `'. $table. '`';
	my $c = 0;
	while (my $line = <$SQL>) {
		$c += 1;
		if ($line =~ /^$table_creation/) {
			my $column_no = 0;
			my $column_matcher = '  `'.$column_name.'`';
			while ($line = <$SQL>) {
				$c += 1;
				$column_no += 1;
				if ($line =~ /^$column_matcher/) {
					last;
				}
				if ($line =~ /^\)/) {
					print "Could not get line number for $table  $column_name\n";
					return 0;
				}
			}

			my $insert_matcher = 'INSERT INTO `'.$table.'`';
			while ($line = <$SQL>) {
				$c += 1;
				if ($line =~ /^$insert_matcher/) {
					while ($line = <$SQL>) {
						$c += 1;
						if ($line =~ /^\($primary_key_value, /) {
							return $c;
						}
					}
				}
			}
		}
	}
	close $SQL;
	return 0;
}

sub reference_to_meta {
	my $reference = shift;

	my $meta;

	if ( $reference =~ m{
					lib/I18N/db/
					([A-Za-z]+)\.db   # Table name
					:
					([a-z_]+)         # Primary key column name
					=
					([^:]+)          # Primary key value
					:
					([a-z_]+)         # Column name
					# $database_reference
	}x) {
		$meta = {
					type =>
						'DB',
					meta => {
						table => $1,
						primary_key_column => $2,
						primary_key_value => $3,
						column_name => $4,
					}
				};
	}
	elsif ($reference =~ /^[^:]+:\d+$/) {
		my ($filename, $line_no) = split(/:/, $reference);
		$meta = {
					type =>
						'FILE',
					meta =>
						{
							filename => $filename,
							line_no  => $line_no,
						}
				};
	}
	else {
		die "Unsupported reference [$reference]\n";
	}

	return $meta;
}

sub get_source_meta {
	my $references = shift;
	# $reference look like this:
	# "javascript/context_help.js:464
	# lib/I18N/db/Questions.db:question_id=109:question"
	my @source_meta;
	foreach my $reference (split(/\n/, $references)) {
		my $meta = reference_to_meta($reference);
		push @source_meta, $meta;
	}
	return @source_meta;
}

sub edit_file {
	my ($editor, $file_path, $line_no, $misspelled) = @_;
	my $success = 1;

	if ( ! -f $file_path ) {
		print colored ['white on_red'],"ERROR: $file_path does not exits!\n";
		return;
	}

	if (defined $editor) {
		my $cmd = $editor;
		$cmd =~ s/%{filename}/$file_path/g;
		$cmd =~ s/%{line}/$line_no/g;
		$misspelled =~ s/'/\\'/g;
		$cmd =~ s/%{wrongword}/$misspelled/g;
		$success = run_cmd($cmd);
	} else {
		print "No editor defined.\n";
		$success = 0;
	}

	return $success;
}

sub notify_action {
	my ($text) = @_;
	print colored ['green'],$text;
	print "\n";
}

sub get_last_line_no {
	my $file = shift;

	open my $IN, '<', $file
		or die "Could not open $file for counting line numbers";
	my @lines = <$IN>;
	close $IN;
	return scalar @lines;
}

sub get_en_US_msgid_at {
	my $po_line = shift;

	my $po_file = 'en_US.po';

	open my $PO, '<', $po_file
		or die "Could not open $po_file";

	my $line_no = 0;
	my $msgstr = '';

	while (my $line = <$PO>) {
		$line_no += 1;
		if ($line_no == $po_line) {
			chomp $line;
			$msgstr .= $line;
			$msgstr =~ s/^msgid "//;
			$msgstr =~ s/"$//;
			while ($line = <$PO>) {
				if ($line =~ /^msgstr/) {
					close $PO;
					return $msgstr;
				}
				chomp $line;
				$line =~ s/^"//;
				$line =~ s/"$//;
				$msgstr .= $line;
			}
		}
	}

	die "Could not find msgid at line $po_line in $po_file\n";
	close $PO;
}

sub add_MySQL_update_statement_to_file {
	my ($spellcheck_fix_sql_file, $meta, $misspelled, $po_line, $suggested_word) = @_;

	my $table = $meta->{table};
	my $primary_key_column = $meta->{primary_key_column};
	my $primary_key_value = $meta->{primary_key_value};
	my $column_name = $meta->{column_name};

	my $msgid = get_en_US_msgid_at($po_line);

	my $insert_header = 0;
	if (! -f $spellcheck_fix_sql_file ) {
		$insert_header = 1;
	}
	open my $SQL, '>>', $spellcheck_fix_sql_file
		or die "Could not create $spellcheck_fix_sql_file";
	my $q = '';
	if ($primary_key_value !~ /^\d+$/) {
		$q = "'";
	}
	my $new_msgid = $msgid;
	if (defined $suggested_word) {
		#print "BEFORE $new_msgid\n";
		#print "TO REPLACE: $misspelled with $suggested_word\n";
		$new_msgid =~ s/([^[:alpha:]]*)$misspelled([^[:alpha:]]*)/$1$suggested_word$2/;
		$new_msgid =~ s/'/''/g;
		#print "AFTER $new_msgid\n";
		#print "\n\nSuggested word is $suggested_word\n\n";
		#<STDIN>;
	#} else {
		#print "\n\nSUGGESTED WORD not defined\n\n";
		#<STDIN>;
	}
	$msgid =~ s/'/''/g;

	if ($insert_header) {
		my $date = localtime;
		print $SQL "-- spelchek.pl corrections $date\n";
	}

	my $first_part =  sprintf(qq(UPDATE `%s` SET `%s`='),
			                            $table, $column_name);
	my $second_part = sprintf(qq(%s' WHERE `%s`=%s%s%s;),
				                 $new_msgid,
				                            $primary_key_column,
				                                $q,$primary_key_value,$q,
				             );
	my $spaces = length($first_part) - length('-- ');
	my $original = sprintf("-- %" . $spaces . "s%s", 'Original text: ', $msgid);
	print $SQL $original . "\n";
	# print $SQL $msgid . "\n";
	my $sql_statement = $first_part . $second_part;

	printf $SQL $sql_statement . "\n";
	close $SQL;

	return ($original, $sql_statement);
}

1;

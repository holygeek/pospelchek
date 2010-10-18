package PO;

# Returns the line number of the $po_file where $msgid_needle is found.
# Returns the line number of the corresponding msgstr if $for_msgstr is defined.
sub get_po_line {
	my ($po_file, $msgid_needle, $for_msgstr) = @_;

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
						#debug "NEEDLE \n[$msgid_needle]\n";
						#debug "MSGID  \n[$msgid]\n";
						#debug "line_no is [$line_no]\n";
						if (defined $for_msgstr) {
							#debug("returning for msgstr: $msgstr_line_no\n");
							return $msgstr_line_no;
						} else {
							#debug("returning for msgsid: $msgid_line_no\n");
							return $msgid_line_no;
						}
					}
					last;
				}
			}
		}
	}
	return 0;
}

1;

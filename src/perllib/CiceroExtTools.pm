package CiceroExtToolsI;

## Exit codes:
## 20: Error calling assembler (cap3)
## 21: Error sorting BLAT output in Mapper->run
## 22: Error sorting BLAT output in overhang_remapping
## 23: Error running aligner (Aligner->run)
## 24: Error running fastmap secondary aligner (Aligner->run)

# this package has three major tools that the program is going to use:
# 1. Assembler, cap3 is used for this purpose
# 2. Mapper, blat server version is used and highly recommended
# 3. Aligner, any one will work, but the program need to parse the output 
sub new {
	my $class = shift;
	my %param = @_;
	my $self = {};
	$self->{PRG} = undef;
	$self->{OPTIONS} = undef;
	foreach my $k (keys %param) {
		my $k1 = $k;
		$k1 = substr($k, 1) if($k =~ m/^-/);
		$self->{$k1} = $param{$k};
	}

	bless $self, ref($class) || $class;
	return $self;
}

sub program {
	my ($self, $value) = @_;
	$self->{PRG} = $value if($value);
	return $self->{PRG};
}

sub options {
	my ($self, $value) = @_;
	$self->{OPTIONS} = $value if($value);
	return $self->{OPTIONS};
}

sub run {
	print STDERR "you need implement your own run method";
}

package Assembler;
use strict;
use Carp;
use English;
use base qw(CiceroExtToolsI);

sub new {
	my ($class, @args) = @_;
	my $self = $class->SUPER::new(@args);
	$self->{PRG} = "cap3" if(!$self->{PRG});
	$self->{OPTIONS} = "" if(!$self->{OPTIONS});
	return $self;
}

# the run function of Assembler returns the contig file and 
# a hashref with the number of reads in each contig

sub run {
	my($self, $file) = @_;
	croak "$self->{PRG} need an input fasta file to do the assembly" if(!$file);
	#my $filesize = -s "$file";
	#print STDERR "size of $file is $filesize\n";
	if(-s $file == 0) {
		print STDERR "$file is of size 0";
		return;
	}
	my $ret = system(join(" ", ($self->{PRG}, $file, $self->{OPTIONS})));
	if ($ret){
		my $err = $!;
		print STDERR "Error running assembler: $err\n"; 
		exit 20;
	}
	my( $r_count, $r_reads ) = _count_reads("$file.cap.ace");
	return ("$file.cap.contigs", $r_count, $r_reads, "$file.cap.singlets");
}

sub _count_reads {
	my $file = shift;
	my %count;
	my %reads;
    open my $ACE, "<$file" or croak "Can't open $file:$OS_ERROR";
	my $contig_name;
    while( my $line = <$ACE> ) {
        if($line =~ m/^CO\s(.*?)\s\d+\s(\d+)/){
			$contig_name = $1;
			$count{$contig_name} = $2;
			#print STDERR "inside cap3 assembly --> contig: $contig_name\tcount: $count{$contig_name}\n";
			$reads{$contig_name} = [];
		}
		if($line =~ m/^RD\s(.*?)\s/) {
			push @{$reads{$contig_name}}, $1;	
		}
	}
	close($ACE);
	return (\%count, \%reads);
}

package Mapper;
use strict;
use Carp;
use Data::Dumper;
use English;
use Bio::SearchIO;
use Bio::SeqIO;
use CiceroSCValidator qw(LEFT_CLIP RIGHT_CLIP);
use base qw(CiceroExtToolsI);

sub new {
	my ($class, @args) = @_;
	my $self = $class->SUPER::new(@args);
	$self->{MIN_HIT_LEN} = 25 if(!$self->{MIN_HIT_LEN});
	$self->{MAX_NUM_HITS} = 3 if(!$self->{MAX_NUM_HITS});
	$self->{MIN_FS_DIST} = 100000 if(!$self->{MIN_FS_DIST});
	return $self;
}

sub max_num_hits {
	my $self = shift;
	my $value = shift;
	$self->{MAX_NUM_HITS} = $value if($value);
	return $self->{MAX_NUM_HITS};
}

sub read_fa_file {
	my $file = shift;
	my $in = Bio::SeqIO->new(-file => $file, -format => 'Fasta');
	my %seqs;
	while( my $seq=$in->next_seq()) {
		$seqs{$seq->display_id} = $seq->seq;
	}
	return \%seqs;
}

sub run {
	my $self = shift;
	my %param = @_;
	croak "Missing QUERY parameter for $self->{PRG}" if(!$param{-QUERY});
	my $contig_file = $param{-QUERY};
	my $unsorted_psl = "$contig_file.unsorted.psl";
	my $psl_file = "$contig_file.psl";
	my $options = $param{-OPTIONS} || $self->{OPTIONS};
	my $sc_chr = $param{-scChr};
	my $sc_site = $param{-scSite};
	my $clip = $param{-CLIP};
	my $read_len = $param{-READ_LEN};
	my $tentative_anchor = $param{-anchorBP} || "0:0";

	my $debug = 0;
	$options = "-minScore=".$self->{MIN_HIT_LEN}." ".$options;
	# Run BLAT 
	my $test = system(join(" ", ($self->{PRG}, $self->{BIT2_DIR}, $param{-QUERY}, $unsorted_psl, $options)));
	# Check if it ran ($test!=0) and if not retry up to 10 times, waiting 3m between attempts. 
	for(my $i=0; $i<10 && $test!=0; $i++){
		print STDERR "failed and resubmiting...\n", join(" ", ($self->{PRG}, $self->{BIT2_DIR}, $param{-QUERY}, $psl_file, $options)), "\n";
		`sleep 3m`;
		$test = system(join(" ", ($self->{PRG}, $self->{BIT2_DIR}, $param{-QUERY}, $unsorted_psl, $options)));
	}
	croak "Please check BLAT server is correctly configured or running.\n" if($test != 0);
	print STDERR "\ntest=$test\t", join(" ", ($self->{PRG}, $self->{BIT2_DIR}, $param{-QUERY}, $unsorted_psl, $options)), "\n" if($debug);
	# Sort the output PSL file from BLAT.
	`sort -k 11,11nr -k 10,10d -k 14,14d -k 1,1nr $unsorted_psl -o $psl_file`;
	if ($?){
		my $err = $!;
		print STDERR "Error sorting blat output: $err\n"; 
		exit 21;
	}

	# Instantiate a parser and load the results into an array to pass to subroutines for checks.
	# A "result" is everything for a given query
	my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	my @results = ();
	while (my $result = $parser->next_result){
		push(@results, $result); 
	}

	# Read the contigs in FASTA format that were generated by the assembler and 
	# mapped with BLAT 
	my $contig_seqs = read_fa_file($contig_file);
	# Check if the contig is fully mapped to somewhere other than the SC site
	my ($bad_contigs,$SC_mapped_contigs, $best_matches) = $self->remove_artificial_contigs( -QUERY => $contig_file, -scChr => $sc_chr, -scSite=>$sc_site, -CLIP=>$clip, -READ_LEN => $read_len, -RESULT => \@results);
	# Count the contigs in each bucket: total contigs, "bad" contigs, and contigs mapped to SC site.
	my ($n_ctg, $n_bad_ctg, $n_SC_ctg) = (scalar (keys %{$contig_seqs}), scalar (keys %{$bad_contigs}), scalar (keys %{$SC_mapped_contigs}));
	print STDERR join("\t", "bad_contigs", keys %{$bad_contigs}), "\n", join("\t", "SC_mapped_contigs", keys %{$SC_mapped_contigs}), "\n", "n_ctg == n_bad_ctg + n_SC_ctg? $n_ctg == $n_bad_ctg + $n_SC_ctg\n" if($debug);
	# If all contigs are bad, return
	return if($n_ctg == $n_bad_ctg);

	my @SC_SVs = ();
	my @result_SVs = ();
	# Parse the BLAT mappings and determine SVs supported by the sc sites
	push @SC_SVs, $self->sv_from_SC_mapping( -QUERY => $contig_file, -scChr => $sc_chr, -scSite=>$sc_site, -CLIP=>$clip, -READ_LEN => $read_len, -SC => $SC_mapped_contigs, -RESULT => \@results) if($n_SC_ctg > 0);
	print STDERR "number of SVs from SC mapping: ", scalar @SC_SVs,"\n" if($debug);
	my $sc_mapped = 0;
	foreach my $sv (@SC_SVs){
		push @result_SVs, $sv;
		next if($sv->{itd});
		my ($bp1, $bp2, $qseq) = ($sv->{first_bp}, $sv->{second_bp}, $sv->{junc_seq});
		print STDERR "..... ", join("\t", $sv->{contig_name}, $sv->{first_bp}->{tpos}, $sv->{second_bp}->{tpos}, $bp1->{ort}, $bp2->{ort}), "\n" if($debug);
		my ($matchesA, $matchesB) = ($bp1->{matches}, $bp2->{matches});
		my $ctg_len = length($qseq);
		$sc_mapped = 1 if($matchesA + $matchesB > $ctg_len - $self->{MIN_HIT_LEN} && abs($bp1->{tpos} - $bp2->{tpos}) < $self->{MIN_FS_DIST});
	}
	# If the we have a mapped contig and all contigs have been categorized as bad or SC
	return @SC_SVs if($sc_mapped && $n_ctg == $n_bad_ctg + $n_SC_ctg);

	print STDERR "++++min_hit_len: ", $self->{MIN_HIT_LEN}, "\n" if($debug);
	print STDERR "partial_mappings = self->select_sc_contig($psl_file, $sc_chr, $sc_site, $clip, $read_len)\n" if($debug);
	# Find contigs that partially map to the soft clip site and trim the match back to the soft clip site.
	my $partial_mappings = $self->select_sc_contig( -QUERY => $contig_file, -scChr => $sc_chr, -scSite=>$sc_site, -CLIP=>$clip, -READ_LEN => $read_len, -BAD => $bad_contigs, -RESULT => \@results);
	my %partial_mappings = %{$partial_mappings};
	#return if(!@partial_mappings);
	my $n_m = scalar (keys %partial_mappings);
	print STDERR "number of partial_mappings: ", $n_m, "\n" if($debug);
	return @SC_SVs if($n_m==0);

	foreach my $qname (keys %partial_mappings){
		my $pm = $partial_mappings{$qname};
		#next if($pm->{low_complexity} == 1);#Tian, rescue IGH-DUX4 for the situation: the SC reads at IGH, but SC part can be mupltiple mapping to DUX4 loci
		my @tmp1_SVs = ();
		print STDERR "\n*****mapping: ", $pm->{qname}, "\tpm->ort: ", $pm->{ort}, "\n" if($debug);
		my $locally_mapped = 0;
		my $local_matches = 0;
		my @this_contig_SC_SVs = ();
		my $ctg_len = length($pm->{qseq});
		foreach my $sv (@SC_SVs){
			next unless($sv->{contig_name} eq $qname);
			#push @this_contig_SC_SVs, $sv;
			my ($matchesA, $matchesB) = ($sv->{first_bp}->{matches}, $sv->{second_bp}->{matches});
			$local_matches = $matchesA + $matchesB if($local_matches < $matchesA + $matchesB);
			#push @tmp1_SVs, $sv;
			$locally_mapped = 1 if(!$sv->{itd} && $matchesA + $matchesB / $ctg_len > 0.99);
		}
		print STDERR "local_matches: $local_matches\n" if($debug);

		print STDERR "locally_mapped? $locally_mapped\n" if($debug);
		@tmp1_SVs = $self->overhang_intrachr_mapping(-QUERY => $contig_file, -scChr => $sc_chr, -scSite=>$sc_site, -CLIP=>$clip, -READ_LEN => $read_len, -SC_PM => $pm, -RESULT => \@results) unless($locally_mapped);
		print STDERR "===finished overhang_intrachr_mapping===\nnumber of mappings: ", scalar @tmp1_SVs, "\n" if($debug);
		#to check the quality of intra_chrom_mapping
		foreach my $sv (@tmp1_SVs){
			my ($bp1, $bp2) = ($sv->{first_bp}, $sv->{second_bp});
			my ($matchesA, $matchesB) = ($bp1->{matches}, $bp2->{matches});
			print STDERR "..... ", join("\t", $bp1->{tname}, $bp2->{tname}, $bp1->{tpos}, $bp2->{tpos}, $bp1->{ort}, $bp2->{ort}, $matchesA, $matchesB), "\n" if($debug);
			next if($local_matches >= $matchesA + $matchesB);
			if(abs($bp1->{tpos} - $bp2->{tpos}) > $self->{MIN_FS_DIST}){
				$sv->{local} = 0; next;
			}
			$sv->{local} = 1;
			$local_matches = $matchesA + $matchesB;
			$locally_mapped = 1 if($matchesA > 2*$self->{MIN_HIT_LEN} && $matchesB > 2*$self->{MIN_HIT_LEN} 
					        || $local_matches > $ctg_len - $self->{MIN_HIT_LEN});
		}
		print STDERR "local_matches: $local_matches\tctg_len: $ctg_len\tlocally_mapped? $locally_mapped\n" if($debug);
		
		my @tmp2_SVs = ();
		if(!$locally_mapped){
			push @tmp2_SVs, $self->select_overhang_mapping($psl_file, $tentative_anchor, $pm, @results);
			print STDERR "===finished select_overhang_mapping===\nnumber of mappings: ", scalar @tmp2_SVs, "\n" if($debug);
			if(!@tmp2_SVs && !@tmp1_SVs){
		 		print STDERR "\noverhang remapping...\n" if($debug);
				push @tmp2_SVs, $self->overhang_remapping(-QUERY => $contig_file, -scChr => $sc_chr, -scSite=>$sc_site, -anchorBP => $tentative_anchor, -SC_PM => $pm);
				print STDERR "===finished overhang_remapping===\nnumber of mappings: ", scalar @tmp2_SVs, "\n" if($debug);
			}
		}

		my @tmp3_SVs = ();
		print STDERR "number of mappings: ", join("\t", scalar @tmp1_SVs, scalar @tmp2_SVs), "\n" if($debug);
		foreach my $sv (@tmp1_SVs, @tmp2_SVs){
			next unless($sv->{contig_name} eq $qname);
			my ($bp1, $bp2) = ($sv->{first_bp}, $sv->{second_bp});
			$sv->{local} = 0;
			$sv->{local} = 1 if($bp1->{tname} eq $bp2->{tname} && abs($bp1->{tpos} - $bp2->{tpos}) < $self->{MIN_FS_DIST});
			if($sv->{local}){
				#if sc mapped, then keep both sc mapping and other mappings in case the sc mapping is not accurate
				next if(!exists($SC_mapped_contigs->{$qname}) && $bp1->{matches} + $bp2->{matches} < $local_matches);
			}
			else{
				next if($bp1->{matches} + $bp2->{matches} < $local_matches + 5);
				#print STDERR "next if(", $sv->{first_bp}->{matches}," + ", $sv->{second_bp}->{matches}," <= $local_matches + 5)\n";
			}
			print STDERR " == push \@tmp3_SVs, ", join("\t", $sv, $bp1->{tpos}, $bp2->{tpos}, $bp1->{repeat}, $bp2->{repeat}), "\n" if($debug);
			push @tmp3_SVs, $sv;
		}
		$locally_mapped = 1 if(scalar @tmp3_SVs == 0);
		foreach my $sv (@this_contig_SC_SVs){
			next if($sv->{one_segment});
			$sv->{local} = 1;
			next if($sv->{first_bp}->{matches} + $sv->{second_bp}->{matches} < $local_matches);
			push @tmp3_SVs, $sv;
			print STDERR " === push \@tmp3_SVs, ", join("\t", $sv, $sv->{first_bp}->{tpos}, $sv->{second_bp}->{tpos}), "\n" if($debug);
		}
		print STDERR "next if (", scalar @tmp3_SVs, " >= ", $self->{MAX_NUM_HITS}," &&  $ctg_len < $read_len + 5)\n" if($debug);
		next if (scalar @tmp3_SVs >= $self->{MAX_NUM_HITS} && $ctg_len < $read_len + 5);

		# if multiple hits, select top X hits
		my @total_matches = ();
		my $total_matches_cutoff = 0;
		if(scalar @tmp3_SVs > $self->{MAX_NUM_HITS}){
			foreach my $sv (@tmp3_SVs){
				my ($bp1, $bp2) = ($sv->{first_bp}, $sv->{second_bp});
				push @total_matches, $bp1->{matches} + $bp2->{matches};
			}
			my @sorted_total_matches = sort { $b <=> $a } @total_matches;
			$total_matches_cutoff = @sorted_total_matches[$self->{MAX_NUM_HITS} - 1];
		}

		# to process mappings for the current contig
		# 1. handle multiple mapping
		# 2. check local mapping at the second breakpoint
		# 3. remove the mappings if it is the same as other contigs
		my @this_contig_SVs = ();
		foreach my $sv (@tmp3_SVs){
			my ($bp1, $bp2, $qseq, $qname) = ($sv->{first_bp}, $sv->{second_bp}, $sv->{junc_seq}, $sv->{contig_name});
			print STDERR "-**-** ", join("**", $bp1->{tpos}, $bp2->{tpos}, $sv->{first_bp}->{ort}, $sv->{second_bp}->{ort}, ), "\n" if($debug);

                        $bp1->{tpos} = ($bp1->{qstrand}*$bp1->{ort}<0) ? $bp1->{tstart} : $bp1->{tend};
                        $bp2->{tpos} = ($bp2->{qstrand}*$bp2->{ort}<0) ? $bp2->{tstart} : $bp2->{tend};
			$bp1->{qpos} = ($bp1->{ort} > 0)? $bp1->{qend} : $bp1->{qstart};
			$bp2->{qpos} = ($bp2->{ort} > 0)? $bp2->{qend} : $bp2->{qstart};
			next if($bp1->{matches} + $bp2->{matches} < $total_matches_cutoff);
			next if ($bp1->{matches} + $bp2->{matches} < $best_matches->{$qname});
			print STDERR "next if (bp1->{matches} + bp2->{matches} <  best_matches->{$qname}) === ", $best_matches->{$qname}, "\n" if($debug);
			print STDERR "next if (", $bp1->{matches}," + ", $bp2->{matches}," < ", $best_matches->{$qname},")\n" if($debug);
			last if(scalar @this_contig_SVs == $self->{MAX_NUM_HITS});
			if($bp1->{tname} eq $bp2->{tname} && abs($bp1->{tpos} - $bp2->{tpos}) < $self->{MIN_FS_DIST}){
				print STDERR " == push \@this_contig_SVs, ", join("\t", $sv, $bp1->{tpos}, $bp2->{tpos}, $bp1->{repeat}, $bp2->{repeat}), "\n" if($debug);
				push @this_contig_SVs, $sv; last;
			}

			print STDERR join("\t", $bp1->{tname}, $bp2->{tname}, $bp1->{tpos}, $bp2->{tpos}, $self->{MIN_FS_DIST}),"\n" if($debug);
			my $added = 0;
			for(my $i=0; $i<=$#result_SVs; $i++){ # is the fusion supported by other contigs?
				my $curr_sv = $result_SVs[$i];
				my ($cbp1,$cbp2) = ($curr_sv->{first_bp}, $curr_sv->{second_bp});
				if(($bp1->{tname} eq $cbp1->{tname} && abs($cbp1->{tpos} - $bp1->{tpos}) < 50 && $bp2->{tname} eq $cbp2->{tname} && abs($cbp2->{tpos} - $bp2->{tpos}) < 50) ||
				($bp1->{tname} eq $cbp2->{tname} && abs($cbp2->{tpos} - $bp1->{tpos}) < 50 && $bp2->{tname} eq $cbp1->{tname} && abs($cbp1->{tpos} - $bp2->{tpos}) < 50)){
					$added = 1;
					print STDERR "current sv: ", join("\t", $cbp1->{tpos}, $cbp2->{tpos}, $cbp1->{matches}, $cbp2->{matches}), "\n" if($debug);
				}
				if($added){
					$result_SVs[$i] = $sv if($bp1->{matches}*$bp2->{matches} > $cbp1->{matches}*$cbp2->{matches});
					last;
				}
			}
			next if($added);
			#if($added) {@this_contig_SVs = (); last;}
	
			my %second_bp = ($bp1->{tpos}-$sc_site)>50 ? %{$bp1} : %{$bp2};
			my $second_bp = \%second_bp;
			$second_bp->{low_complexity} = 0;
			$second_bp->{qname} = $qname;
			$second_bp->{qseq} = $qseq;
			my ($sc_chr2, $sc_site2, $clip2) = ($second_bp->{tname}, $second_bp->{tpos}, $second_bp->{ort}*$second_bp->{qstrand});
			print STDERR "\n**********\n\nto check the quality of intra_chrom_mapping of $qname at $sc_chr2:$sc_site2, $clip2\n" if($debug);

			print STDERR "\@internal_SVs2 = $self->overhang_intrachr_mapping(-QUERY => $contig_file, -scChr => $sc_chr2, -scSite=>$sc_site2, -CLIP=>$clip2, -READ_LEN => $read_len, -SC_PM => $second_bp)\n" if($debug);
			print STDERR "pm->{qname}: ", $second_bp->{qname}, "\tort: ", $second_bp->{ort}, "\n" if($debug);
			my @internal_SVs2 = $self->overhang_intrachr_mapping(-QUERY => $contig_file, -scChr => $sc_chr2, -scSite=>$sc_site2, -CLIP=>$clip2, -READ_LEN => $read_len, -SC_PM => $second_bp, -RESULT => \@results);
			print STDERR "internal_SVs2: ", scalar (@internal_SVs2), "\n" if($debug);

			#to check the quality of intra_chrom_mapping
			my $mapped_at_second_bp = 0;
			foreach my $sv2 (@internal_SVs2){
				my ($bp21, $bp22, $qseq2, $qname2) = ($sv2->{first_bp}, $sv2->{second_bp}, $sv2->{junc_seq}, $sv2->{contig_name});
				# print STDERR "bp21, bp22, qseq2, qname2", ":\t", join("\t", $bp21, $bp22, $qseq2, $qname2), "\n";
				next unless($qname2 eq $qname);
				next if(abs($bp21->{tpos} - $bp22->{tpos}) > $self->{MIN_FS_DIST});
				my ($matchesA2, $matchesB2) = ($bp21->{matches}, $bp22->{matches});
				$mapped_at_second_bp = 1 if($matchesA2 + $matchesB2 >= $bp1->{matches} + $bp2->{matches});  
				print STDERR "mapped_at_second_bp = 1 if($matchesA2 + $matchesB2 >= ", $bp1->{matches}," + ", $bp2->{matches},")\n" if($debug); 
				my $ctg_len2 = length($qseq2);
				$mapped_at_second_bp = 1 if($matchesA2 > 2*$self->{MIN_HIT_LEN} && $matchesB2 > 2*$self->{MIN_HIT_LEN} 
						        || $matchesA2 + $matchesB2 > $ctg_len2 - 2*$self->{MIN_HIT_LEN});
				#$mapped_at_second_bp = 1 if($matchesA2 + $matchesB2 > $ctg_len2 - 25 && abs($bp21->{tpos} - $bp22->{tpos}) < $self->{MIN_FS_DIST});
			}
			print STDERR "last if($mapped_at_second_bp)\n" if($debug);
			if($mapped_at_second_bp) {@this_contig_SVs = (); last;}
			print STDERR "-*-* ", join("\t", $sv->{first_bp}->{tpos}, $sv->{second_bp}->{tpos}, $sv->{first_bp}->{ort}, $sv->{second_bp}->{ort}), "\n" if($debug);
			print STDERR " === push \@this_contig_SVs, ", join("\t", $sv, $bp1->{tpos}, $bp2->{tpos}, $bp1->{repeat}, $bp2->{repeat}), "\n" if($debug);
			push @this_contig_SVs, $sv;
		} #finish checking mappings for the current contig
		print STDERR "number of mappings for this_contig_SVs: ", scalar @this_contig_SVs, "\n" if($debug);
		push @result_SVs, @this_contig_SVs;
	} # end foreach contig
	#push @result_SVs, @SC_SVs;
	print STDERR "result_SVs: ", scalar @result_SVs, "\n" if($debug && @result_SVs);
	return @result_SVs if(@result_SVs);
	return;
}

#sub remove_artificial_contigs {
# if the contig is fully mapped to elsewhere not SC site, then it is likely to be false assembled contig or from wrongly collected reads
sub remove_artificial_contigs { 
	my $self = shift;
	my %param = @_;
	my $contig_file = $param{-QUERY};
	my $psl_file = $contig_file.".psl";
	my $read_len = $param{-READ_LEN};
	my $sc_chr = $param{-scChr};
	$sc_chr =~ s/^chr//;
	my $sc_site = $param{-scSite};
	my $tentative_anchor = $param{-anchorBP} || "0:0";
	my $clip = $param{-CLIP};
	my @results = @{$param{-RESULT}};
	
	my $debug = 0;
	print STDERR "\n==== to find bad contigs ====\nPSL_file: $psl_file\n" if($debug);
	#my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');

	my %bad_contigs = (); # to find contigs fully mapped to somewhere other than the SC site
	my %SC_mapped_contigs = (); # to find contigs fully mapped to the SC site
	my %best_matches = (); # to find the longest matches 
	my ($n_contigs, $n_bad) = (0, 0);
	#while( my $result = $parser->next_result ) { #foreach contig
	foreach my $result (@results) {
		# Since we're storing the results, we want to start from the beginning of the matches.
		$result->rewind;
		$n_contigs+=1;
		my ($qname, $contig_len) = ($result->query_name, $result->query_length);
		# Initialize the best match to 0. Then each match will compare and store anything greater.
		$best_matches{$qname} = 0;
		print STDERR "\nqname: $qname, contig_len: $contig_len, sc_site: $sc_site\n" if($debug);
		# If the contig is already assigned to the bad list or the fully mapped list, skip processing the rest of the mappings for this contig.
		next if(exists($bad_contigs{$qname}) || exists($SC_mapped_contigs{$qname}));
		# If the contig is shorter than input sequencing read length, which is specified as an argument to annotate.pl
		if($contig_len <= $read_len) {$bad_contigs{$qname}=1; next;}
		# Process each hit, which is a sequence in the database (usually a chromosome).
		while(my $hit = $result->next_hit) { #foreach chrom
			# Reset the list of pairs to the beginning for searching. 
			$hit->rewind;
			my (@left_mappings, @right_mappings);
			my $tchr = $hit->name;
			$tchr =~ s/^chr//;
			# Process each alignment pair (high-scoring pair [hsp]).
			while( my $hsp = $hit->next_hsp) {
				# Number of identical positions
				my ($n_matches) = $hsp->matches;
				# If the length of identical sequence in this match is better than any seen so far for this contig,
				# store this length as the new "best" match.
				$best_matches{$qname} = $n_matches if($n_matches > $best_matches{$qname});
				my ($tstart, $tend, $qstart, $qend) = ($hsp->start('hit'), $hsp->end('hit'), $hsp->start('query'), $hsp->end('query'));
				print STDERR "**** ", join("\t", $tchr, $tstart, $tend, $qstart, $qend, $hsp->start('query'), $hsp->end('query'),$hsp->strand('query'), $n_matches), "\n" if($debug);
				# The match must be more than MIN_HIT_LEN from the first position of the contig.
				# It must also not be closer than MIN_HIT_LEN to the end of the contig.
				next if($qstart > $self->{MIN_HIT_LEN} && $contig_len - $qend > $self->{MIN_HIT_LEN});

				# remove this line to get internal duplication and readthrough events
				#$bad_contigs{$qname} = 1; print "$qname fully mapped to the soft-clip site\n" if($debug); last;

				# Figure out what portion of the contig is identical match.
				# This should probably just use $hsp->frac_identical
				my $percent = $n_matches/($qend - $qstart + 1);

				# If it is completely aligned ($percent == 1)
				# If there is only one gap block (scalar @{hsp->gap_blocks('hit')} == 1)
				# If the match start position is less than MIN_HIT_LEN from the beginning of the contig ($qstart < $self->{MIN_HIT_LEN})
				# If the end of the match is closer than MIN_HIT_LEN to the end of the contig ($contig_len - $qend < $self->{MIN_HIT_LEN})
				# If all true, this is a bad contig
				# Are conditions 3 & 4 not implied by condition 1?
				if($percent == 1 && scalar @{$hsp->gap_blocks('hit')} == 1 &&
					$qstart < $self->{MIN_HIT_LEN} && $contig_len - $qend < $self->{MIN_HIT_LEN}){
					$bad_contigs{$qname} = 1; last;
				}

				# fully mapped to elsewhere other than soft-clip site
				# If the match start position is less than MIN_HIT_LEN from the beginning of the contig ($qstart < $self->{MIN_HIT_LEN})
				# If the end of the match is closer than MIN_HIT_LEN to the end of the contig ($contig_len - $qend < $self->{MIN_HIT_LEN
				# If it is aligned at greate than 90% identity ($percent > 0.9)
				# If the number of matches is more than query length - 20 ($n_matches > $qend - $qstart - 20)
				# If it is mapped to another chromosome ($tchr ne $sc_chr)
				# If the distance from the reference start to the soft clip site times the distance from the reference end to the soft clips site is greater than 0, e.g. the reference alignment does not cover the soft clip site ($tstart-$sc_site)*($tend-$sc_site)>0)
				if($qstart < $self->{MIN_HIT_LEN} && $contig_len - $qend < $self->{MIN_HIT_LEN} &&
					$percent > 0.9 && $n_matches > $qend - $qstart - 20 &&
					($tchr ne $sc_chr || ($tstart-$sc_site)*($tend-$sc_site)>0)){

						$bad_contigs{$qname} = 1; print STDERR "$qname fully mapped to elsewhere\n" if($debug);
						delete $SC_mapped_contigs{$qname} if(exists($SC_mapped_contigs{$qname})); last;
				}
				# If the chromosome of the match is the same as the soft clip site ($tchr eq $sc_chr)
				# If the alignment in the reference covers the soft clip site and the site isn't within MIN_HIT_LEN/2 of the start or end position ($tstart + $self->{MIN_HIT_LEN}/2 - $sc_site)*($tend - $self->{MIN_HIT_LEN}/2 - $sc_site)<0)
				if($tchr eq $sc_chr && ($tstart + $self->{MIN_HIT_LEN}/2 - $sc_site)*($tend - $self->{MIN_HIT_LEN}/2 - $sc_site)<0){ 
					# Skip if the alignment is 100% and there is only 1 gap block [single contiguous alignment]
					next if($percent == 1 && scalar @{$hsp->gap_blocks('hit')} == 1);
					# If the match start position is less than MIN_HIT_LEN from the beginning of the contig ($qstart < $self->{MIN_HIT_LEN})
					# If the end of the match is closer than MIN_HIT_LEN to the end of the contig ($contig_len - $qend < $self->{MIN_HIT_LEN})
					# If the length of the alignment in the query is greater than 90% of the contig length ($qend - $qstart) > 0.9*$contig_len)
					$SC_mapped_contigs{$qname} = 1 if(($qstart < $self->{MIN_HIT_LEN} && $contig_len - $qend < $self->{MIN_HIT_LEN})
									 || ($qend - $qstart) > 0.9*$contig_len);
					print STDERR "$qname fully mapped to SC site\n" if($debug);
				}
				else{
					# Otherwise we'll store the mapping for further checks.
					my $tmp_mapping = {
						tname	=> $hit->name,
						tstart	=> $hsp->start('hit'),
						tend	=> $hsp->end('hit'),
						qstart	=> $hsp->start('query'),
						qend	=> $hsp->end('query'),
						qstrand => $hsp->strand('query'),
						matches	=> $n_matches,
						percent => $percent
					};
				
					# The right end of the contig may be aligned elsewhere, e.g. the contig may span a break point
					push @left_mappings, $tmp_mapping if($qstart + $qend < $contig_len);
					# The left end of the contig may be aligned elsewhere, e.g. the contig may span a break point
					push @right_mappings, $tmp_mapping if($qstart + $qend >= $contig_len);
				}
			}
			my ($left_sc_bp, $right_sc_bp) = (0, 0);
			# Handle previously identified contigs where the left portion was mapped to the sc site
			foreach my $lm (@left_mappings){ #to check if the contig is mapped to elsewhere (not sc site region)

			   print STDERR "lm: ", join("\t", $lm->{tname}, $lm->{tstart}, $lm->{tend}), "\n" if($debug);
			   # If the chromosome is the same ($sc_chr eq $tchr)
			   # If the query is on the positive strand and the start is left of the sc site and the end is less than 50bp from the sc site
			   # If the query is on the negative strand and the start is less than 50bp from the sc site and the end is more than MIN_HIT_LEN from the sc site.
			   $left_sc_bp = 1 if ($sc_chr eq $tchr && (($lm->{qstrand} > 0 && $lm->{tstart} < $sc_site && abs($lm->{tend} - $sc_site) < 50) ||
						($lm->{qstrand} < 0 && abs($lm->{tstart} - $sc_site) < 50 && $lm->{tend} > $sc_site + $self->{MIN_HIT_LEN})));

			   print STDERR join("\t", $left_sc_bp, $sc_chr, $tchr, $lm->{tstart}, $lm->{tend}, $sc_site), "\n" if($debug);
			   
			   last if($left_sc_bp == 1);
			   # Handle previously identified contigs where the right portion was mapped to the sc site
			   foreach my $rm (@right_mappings){
				print STDERR "rm: ", join("\t", $rm->{tname}, $rm->{tstart}, $rm->{tend}), "\n" if($debug);
				# If the chromosome is the same ($sc_chr eq $tchr)
				# If the query is on the positive strand and the start is less than 50bp from the sc site and the end is past the sc site.
			 	# If the query is on the negative strand and the start more than MIN_HIT_LEN left of the sc site and the end is less than 50bp from the sc site
			   	$right_sc_bp = 1 if ($sc_chr eq $tchr && (($rm->{qstrand} > 0 && abs($rm->{tstart} - $sc_site) < 50 && $rm->{tend} > $sc_site) ||
						($rm->{qstrand} < 0 && $rm->{tstart} < $sc_site - $self->{MIN_HIT_LEN} && abs($rm->{tend} - $sc_site) < 50)));
			   	print STDERR join("\t", $right_sc_bp, $sc_chr, $tchr, $rm->{tstart}, $rm->{tend}, $sc_site), "\n" if($debug);
			   	last if($right_sc_bp == 1);

				# Now we look to see if 

				# If end of the left mapping minus the start of the right mapping is less than the start of the left mapping minus the start of the right mapping, e.g. the alignments don't overlap and lm is upstream of rm
				# Use the distance between the end of the left and the start of the right
				# Otherwise use the distance between the start of the left mapping and the start of the right mapping
				my $dist1 = (abs($lm->{tend}-$rm->{tstart}) < abs($lm->{tstart}-$rm->{tstart})) ? abs($lm->{tend}-$rm->{tstart}) : abs($lm->{tstart}-$rm->{tstart});
				# If end of the left mapping minus the end of the right mapping is less than the start of the left minus the end of the right, e.g. the lm start is upstream of rm start
				# Use the distance between the end of the left and the end of the right
				# Otherwise use the distance between the start of the left and the end of the right
				my $dist2 = (abs($lm->{tend}-$rm->{tend}) < abs($lm->{tstart}-$rm->{tend})) ? abs($lm->{tend}-$rm->{tend}) : abs($lm->{tstart}-$rm->{tend}); 
				# Take the smaller of the distances
			   	my $dist = ($dist1 < $dist2) ? $dist1 : $dist2;
				# If the end of the lm plus MIN_HIT_LEN is beyond the start of rm, e.g. the end of left mapping is within MIN_HIT_LEN of right start or beyond right start
				# And the distance is less than 40kb
			   	$bad_contigs{$qname} = 1 if($lm->{qend} + $self->{MIN_HIT_LEN} > $rm->{qstart} && $dist < 40000);
			   	print STDERR "$qname mapped...\n" if($debug && $lm->{qend} + $self->{MIN_HIT_LEN} > $rm->{qstart} && $dist < 40000 && $debug);
			   }
			   #last unless($left_sc_bp + $right_sc_bp == 0);
			}
			last if(exists($bad_contigs{$qname}));
		} # end foreach chrom
	}	
	$n_bad = scalar (keys %bad_contigs);
	#print"n_mapped:$n_mapped\nn_contigs:$n_contigs\n";
	#return if ($n_bad == $n_contigs);
	return (\%bad_contigs, \%SC_mapped_contigs,\%best_matches);
} # end of remove artifical contig


###############################################
#
#     sv_from_SC_mapping
#
##############################################
# SC_mapped_contigs is the list of contigs aligned to sc sites after removing bad results.
sub sv_from_SC_mapping { 
	my $self = shift;
	my %param = @_;
	my $contig_file = $param{-QUERY};
	my $psl_file = $contig_file.".psl";
	my $read_len = $param{-READ_LEN};
	my $sc_chr = $param{-scChr};
	my $sc_site = $param{-scSite};
	my $clip = $param{-CLIP};
	my $SC_mapped_contigs = $param{-SC};
	my @results = @{$param{-RESULT}};

	my %SC_mapped_contigs = %{$SC_mapped_contigs}; # Previously found fully mapped contigs
	my $debug = 0;
	print STDERR "\n==== get SV from the contig fully mapped to the SC site ====\nPSL_file: $psl_file\n" if($debug);

	my $contig_seqs = read_fa_file($contig_file);	

	my @rtn;
	#my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	#while( my $result = $parser->next_result ) { #foreach contig
	foreach my $result (@results) {
		$result->rewind;
		my ($qname, $contig_len) = ($result->query_name, $result->query_length);
		next unless(exists($SC_mapped_contigs{$qname})); # Limit to only previously found SC mapped contigs
		print STDERR "checking $qname at $sc_site with clip $clip ...\n" if($debug);
		my (@tmp_SVs, $tmp_SV);
		my $ITD = 0;
		# Check each place the contig mapped
		while( my $hit = $result->next_hit) { #foreach chrom
			$hit->rewind;
			my $tname = $hit->name;	
			next if($tname ne $sc_chr); # Only look at mappings to the SC chromosome
			while( my $hsp = $hit->next_hsp) { # for each "high scoring pair"
				# Number of identical positions
				my ($n_matches) = $hsp->matches;
				my ($tstart, $tend, $qstart, $qend, $qstrand) = ($hsp->start('hit'), $hsp->end('hit'), $hsp->start('query'), $hsp->end('query'), $hsp->strand('query'));
				print STDERR "next if($tstart > $sc_site + 1000 || $tend < $sc_site - 1000)\n" if($debug);
				# Ensure the mapping hit is within 1000bp of the sc_site
				next if($tstart > $sc_site + 1000 || $tend < $sc_site - 1000);
				# Store the array of gap blocks for query and reference.
				my @tblocks = @{$hsp->gap_blocks('hit')};
				my @qblocks = @{$hsp->gap_blocks('query')};

				my ($bp1, $bp2, $qbp1, $qbp2);
				my ($qstart1, $qend1, $tstart1, $tend1);
				my ($qstart2, $qend2, $tstart2, $tend2);
				my $ort	= $clip*$qstrand;
				my $solved = 0;

				my $one_segment = 0;
				# If this contig mapped to one fully contiguous position in the reference
				if(scalar @tblocks == 1){
					($bp1, $bp2) = ($sc_site, $sc_site);
					$qbp1 = ($qstrand > 0) ? $qstart + $sc_site - $tstart : $qstart + $tend - $sc_site;
					$qbp2 = $qbp1;
					$one_segment = 1;
					$solved = 1;
				}
				my $dup_len = 0;
				# The contig was mapped to multiple positions in the reference with gaps, so inspect each region
				# Skips the final block because the comparisons are between the current and next block
				for(my $i = 0; $i < scalar @tblocks - 1; $i++) {
					# Get the block start for matches in the reference and the query contig
					my ($bl, $qbl) = ($tblocks[$i], $qblocks[$i]);
					# Get the start of the next block for reference and query contig
					my ($br, $qbr) = ($tblocks[$i+1], $qblocks[$i+1]);
					print STDERR join("\t", "sc_site","qstart", "qend", "bl->[0]", "bl->[1]", "qbl->[0]", "qbl->[1]"), "\n" if($debug);
					print STDERR join("\t", $sc_site, $qstart, $qend, $bl->[0], $bl->[1], $qbl->[0], $qbl->[1]), "\n" if($debug);
					print STDERR join("\t", $sc_site, $qstart, $qend, $br->[0], $br->[1], $qbr->[0], $qbr->[1]), "\n" if($debug);
					# If the start position of the alignment in the query is < min hit len and the 
					# length of sequence after the alignment is < min hit len
					# e.g. if the alignment length is > ($contig_len - 2 * MIN_HIT_LEN)
					# Then dup len is the (strand * (start of next block - start of current block) - the length of the block
					# Basically it is the distance between the two alignment blocks.
					$dup_len = $qstrand*($qbr->[0] - $qbl->[0]) - $qbl->[1] if($qstart < $self->{MIN_HIT_LEN} && $contig_len - $qend < $self->{MIN_HIT_LEN});
					print STDERR "ITD ? $dup_len\tqstrand:$qstrand\tclip:$clip\n" if($debug);
					# If the alignment in the reference is more than 5 bp from the sc_site
					# ($br->[0] + 5 < $sc_site || $bl->[0]-5 > $sc_site)
					next if($dup_len <= 10 && ($br->[0] + 5 < $sc_site || $bl->[0]-5 > $sc_site));
					if($dup_len > 10){
						$ITD = 1;
						print STDERR join("\t", $bl->[0],  $qbl->[1], $br->[0], abs($bl->[0] + $qbl->[1] - $br->[0])), "\n" if($debug);
						$bp1 = $sc_site;
						$bp2 = $bp1 - $clip*$dup_len;
						$qbp1 = $qbr->[0];
						$qbp2 = $qbp1;
						print STDERR join("\t", "dup_len: $dup_len", "clip: $clip", "bp1:$bp1", "bp2:$bp2", "qbp1:$qbp1", "qbp2:$qbp2"), "\n" if($debug);
					}
					else{ #deletion or readthrough events
							$bp1 = ($clip > 0) ? $bl->[0] + $qbl->[1] : $br->[0];
							$bp2 = ($clip > 0) ? $br->[0] : $bl->[0] + $qbl->[1];
							$qbp1 = $qbl->[0] + $qstrand*$qbl->[1]; $qbp2 = $qbr->[0];
					}
					print STDERR "solved\tbp1:$bp1\tbp2:$bp2\tqbp1:$qbp1\tqbp2:$qbp2\n" if($debug);
					$solved = 1; last;
				}
				last unless($solved);
				($qstart1, $qend1) = ($ort > 0) ? ($qstart, $qbp1) : ($qbp1, $qend);
				($qstart2, $qend2) = ($ort > 0) ? ($qbp2, $qend) : ($qstart, $qbp2);
				($tstart1, $tend1) = ($clip > 0) ? ($tstart, $bp1) : ($bp1, $tend);

				my $pm = {
					ort	=> $ort,
					tname	=> $tname,
					tstart	=> $tstart1,
					tend	=> $tend1,
					tpos	=> $bp1,
					qstart	=> $qstart1,
					qend	=> $qend1,
					qpos	=> $qbp1,
					qstrand => $qstrand,
					matches	=> $qend1 - $qstart1 + 1,
					percent => 1,
					repeat	=> 0
				};

				my $ort2 = -1*$ort; 
				my $clip2 = $ort2*$qstrand;
				($tstart2, $tend2) = ($clip2 > 0) ? ($tstart, $bp2) : ($bp2, $tend);
				my $m = {
					ort	=> $ort2,
					tname	=> $tname,
					tstart	=> $tstart2,
					tend	=> $tend2,
					tpos	=> $bp2,
					qstart	=> $qstart2,
					qend	=> $qend2,
					qpos	=> $qbp2,
					qstrand => $qstrand,
					matches	=> $qend2 - $qstart2 + 1,
					percent => 1,
					repeat	=> 0
				};
				next if($pm->{matches} < $self->{MIN_HIT_LEN} || $m->{matches} < $self->{MIN_HIT_LEN});

				my $qseq = $contig_seqs->{$qname};
				$tmp_SV = {
					contig_name => $qname,
					junc_seq => $qseq,
					first_bp => $pm,
					second_bp => $m,
					one_segment => $one_segment,
					itd => $ITD,
				};
				push @rtn, $tmp_SV; last;
			}
		}
	}
	return @rtn;
}

###############################################
#
#     overhang_intrachr_mapping
#
##############################################
sub overhang_intrachr_mapping { 
	my $self = shift;
	my %param = @_;
	my $contig_file = $param{-QUERY};
	my $psl_file = $contig_file.".psl";
	my $options = $param{-OPTIONS} || $self->{OPTIONS};
	my $read_len = $param{-READ_LEN};
	my $sc_chr = $param{-scChr};
	$sc_chr =~ s/^chr//;
	my $scSite = $param{-scSite};
	my $tentative_anchor = $param{-anchorBP} || "0:0";
	my $clip = $param{-CLIP};
	my $pm = $param{-SC_PM};
	my @results = @{$param{-RESULT}};


	my $intrachr_mapped = 1;
	my $debug = 0;
	print STDERR "\n==== start to find SC mapping in the same chrom for ", $pm->{qname}," ====\nPSL_file: $psl_file\n" if($debug);
	my @rtn;
	#my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	#while( my $result = $parser->next_result ) { #foreach contig
	foreach my $result (@results) {
		$result->rewind;	
		my ($qname, $contig_len) = ($result->query_name, $result->query_length);
		next unless($qname eq $pm->{qname});
		print STDERR "qname: $qname", "\t", $pm->{qname}, " at chr", $sc_chr, ":$scSite", "\n" if($debug);
		my (@tmp_SVs, $tmp_SV);
		my $qseq = $pm->{qseq};
		while( my $hit = $result->next_hit) { #foreach chrom
			$hit->rewind;
			my $tchr = $hit->name;
			$tchr =~ s/^chr//;
			next if($tchr ne $sc_chr);
			my @overhang_mappings;
			my $min_dist=$self->{MIN_FS_DIST};
			my $min_dist_identity=0;
			my $min_dist_match=0;
			my $max_match=0;
			my $segment_length = ($pm->{ort} > 0) ? ($contig_len - $pm->{qend}) : $pm->{qstart};
			my $matches_cutoff = $self->{MIN_HIT_LEN};
			#my $matches_cutoff = ($segment_length*0.75 > 25) ? $segment_length*0.75 : 25;

			while( my $hsp = $hit->next_hsp) {
				my ($n_matches) = $hsp->matches;
				my ($n_mis_matches) = $hsp->mismatches;
				#next if($hsp->start('query') > $min_hit_len && $hit->query_length - $hsp->end('query') > $min_hit_len);# || $percent < 0.9;

				my ($tstart, $tend, $qstart, $qend, $qstrand) = ($hsp->start('hit'), $hsp->end('hit'), $hsp->start('query'), $hsp->end('query'), $hsp->strand('query'));
				#next if(abs($tstart-$scSite)>100000 && abs($tend-$scSite)>100000);

				my $is_overlap = 0;
				#print join(" = ", $pm->{ort}, $qstart, $pm->{qpos}, $qend, $pm->{qpos} + 50), "\n";
				$is_overlap = 1 if(($pm->{ort} > 0 && $qstart < $pm->{qpos}  && $qend > $pm->{qpos} + 10) ||
						  ($pm->{ort} < 0 && $qend > $pm->{qpos} && $qstart < $pm->{qpos} - 10));
				#$is_overlap = 1 if(($pm->{ort} > 0 && $qstart < $pm->{qpos}  && $qend > $pm->{qpos} + 50) ||
				#		  ($pm->{ort} < 0 && $qend > $pm->{qpos} && $qstart < $pm->{qpos} - 50));
				my $m_ort = $qstart + $qend < 2*$pm->{qpos}? 1 : -1;
#				print STDERR "my $m_ort = $qstart + $qend < 2*", $pm->{qpos}, "? 1 : -1\n";
#				next if($m_ort == $pm->{ort});
				my $same_ort = (abs($qstart - $pm->{qstart}) < 25 && abs($qend - $pm->{end}) < 25) ? 1 : 0;
				next if($same_ort); $m_ort = -1*$pm->{ort};

				my $clip2 = $m_ort*$qstrand;
				print STDERR "\nis_overlap? $is_overlap\n" if($debug);
				# need to trim the wrongly mapped region.
				my @tblocks = @{$hsp->gap_blocks('hit')};
				my @qblocks = @{$hsp->gap_blocks('query')};
				print STDERR "clip2: $clip2\n", join("\t", "pm:", $pm->{ort}, $pm->{tname}, $pm->{tstart}, $pm->{tend}, $pm->{qstart}, $pm->{qend}, $pm->{qstrand}, 
				"\nm:", $tchr, $qstart, $qend, $pm->{qpos}, $tstart, $tend), "\n" if($debug);

				if($clip2 > 0 && $is_overlap){
					for(my $i=$#tblocks; $i>=0; $i--) {
						my ($bl, $qbl) = ($tblocks[$i], $qblocks[$i]);
						print join("\t", $pm->{ort}, $qstart, $qend, $bl->[0], $bl->[1], $qbl->[0], $qbl->[1], $pm->{qpos}), "\n" if($debug);
						#next if($bl->[0] > $scSite - $min_hit_len){
						if(($qstrand > 0 && $qbl->[0] > $pm->{qpos}) ||
						   ($qstrand < 0 && $qbl->[0] < $pm->{qpos})){
							$n_matches -= $qbl->[1];
							next;
						}
						my $over_hang = ($qstrand > 0) ? $qbl->[0] + $qbl->[1] - $pm->{qpos} :  $pm->{qpos} - $qbl->[0];
						last if($over_hang < 0); 
						print STDERR "over_hang: ", join("\t",$over_hang, $bl->[0], $bl->[1], $qbl->[0], $qbl->[1]), "\n" if($debug);
						$tend = $bl->[0] + $bl->[1] - $over_hang + 1;
						$n_matches -= $over_hang;
						$qstart = $pm->{qpos} if($qstrand<0); 
						$qend = $pm->{qpos} if($qstrand>0); 
						last;
					}
				}
				print STDERR "n_matches: $n_matches\ttstart: $tstart\ttend: $tend\tqstart: $qstart\tqend: $qend\n" if($debug);

				#print "number of fragments: ", scalar @tblocks, "\n";
				if($clip2 < 0 && $is_overlap){
					for(my $i=0; $i<=$#tblocks; $i++) {
						my ($bl, $qbl) = ($tblocks[$i], $qblocks[$i]);
						print STDERR "==== ", join("\t", $pm->{ort}, $qstart, $qend, $qbl->[0], $qbl->[1], $bl->[0], $bl->[1], $pm->{qpos}), "\n" if($debug);
						if(($qstrand > 0 && $qbl->[0] + $qbl->[1] < $pm->{qpos}) ||
						   ($qstrand < 0 && $qbl->[0] - $qbl->[1] > $pm->{qpos})){
							$n_matches -= $qbl->[1];
							next;
						}
						my $over_hang = ($qstrand > 0)? $pm->{qpos} - $qbl->[0] : $qbl->[0] - $pm->{qpos};
						last if($over_hang < 0); 
						print STDERR "over_hang: ", join("\t",$over_hang, $bl->[0], $bl->[1], $qbl->[0], $qbl->[1]), "\n" if($debug);
						$tstart = $bl->[0] + $over_hang + 1;
						$n_matches -= $over_hang;
						$qend = $pm->{qpos} if($qstrand<0); 
						$qstart = $pm->{qpos} if($qstrand>0); 
						print STDERR "left-clip n_matches: $n_matches\n\n" if($debug);
						last;
					}
				}
				print STDERR "***n_matches: $n_matches\ttstart: $tstart\ttend: $tend\tqstart: $qstart\tqend: $qend\n" if($debug);

				my $m = {
					tname	=> $hit->name,
					tstart	=> $tstart,
					tend	=> $tend,
					qstart	=> $qstart,
					qend	=> $qend,
					qstrand => $hsp->strand('query'),
					matches	=> $n_matches,
					percent => ($n_matches - $n_mis_matches)/($qend - $qstart + 1)
					#percent => $n_matches/($hsp->end('query') - $hsp->start('query') + 1)
				};

				print STDERR "m->{ort} = ($qstart+$qend < 2*$pm->{qpos}) ? 1 : -1\n" if($debug);
				$m->{ort} = ($qstart+$qend < 2*$pm->{qpos}) ? 1 : -1;
				if($m->{ort} == $pm->{ort}) {printf STDERR"same segment!!!\n\n" if($debug); next;}
				if($pm->{qstart} > $m->{qstart} - 10 && $pm->{qend} < $m->{qend} + 10) {printf STDERR"same segment and overlap!!!\n\n" if($debug); next;}
				my $m_tpos = ($m->{qstrand}*$m->{ort}<0) ? $m->{tstart} : $m->{tend};
				$m->{qpos} = ($m->{ort} > 0) ? ($qend, $qstart) : ($qstart, $qend);
				$m->{tpos} = $m_tpos;

				my $m_qpos = ($m->{ort}<0) ? $m->{qstart} : $m->{qend};
				my $gap = abs($m_qpos - $pm->{qpos});
				next if($gap > $read_len - 25);
				my $unmapped_end = ($m->{ort}<0) ? $contig_len - $m->{qend} : $m->{qstart};

				if(($m->{percent}>=0.99 && $m->{matches}>25) || 
				($m->{matches} > $matches_cutoff && $m->{percent} > 0.75)){
					 push @overhang_mappings, $m;
					print STDERR "---===m_tpos:$m_tpos\tpm_tpos: ", $pm->{tpos}, " ===---\n\n" if($debug);

					my $dist = abs($m->{tpos} - $pm->{tpos});
					if($dist < $min_dist && $contig_len - ($pm->{matches} + $m->{matches}) < $matches_cutoff){
						$min_dist = abs($m_tpos - $pm->{tpos});
						$min_dist_identity = $m->{percent};
						$min_dist_match = $m->{matches};
						print STDERR "---===m_tpos:$m_tpos\tpm_tpos: ", $pm->{tpos}, "\tmin_dist: $min_dist ===---\n\n" if($debug);
					}
				}

				print STDERR "m->{matches}: ", $m->{matches}, "\tsegment_length: ", $segment_length, "\tmax_match: $max_match\tm->{percent}: ",$m->{percent},"\n" if($debug);
				if($m->{matches} >= $segment_length*0.95 && $m->{matches} >= $max_match && $m->{percent} >= 0.95){
					$max_match = $m->{matches};
				}
				#push @overhang_mappings, $m if($qstart <= $min_hit_len && $pm->{ort} < 0);
				#push @overhang_mappings, $m if($contig_len - $qend <= $min_hit_len && $pm->{ort} > 0); 
			} # obtained all the possible sc mappings in the sc_chr

			print STDERR "number of overhang mappings: ", scalar @overhang_mappings, "\n" if($debug);
			my $n_overhang = scalar @overhang_mappings;
			return if($n_overhang == 0);

			print STDERR "\n---=== min_dist: $min_dist\tmin_dist_match: $min_dist_match\tmatches_cutoff: $matches_cutoff\tmin_dist_identity: $min_dist_identity ===---\n" if($debug);

			foreach my $m (@overhang_mappings){ #to check if the contig is mapped to elsewhere (not sc site region)

				$tmp_SV = {
					contig_name => $qname,
					junc_seq => $qseq,
					first_bp => $pm,
					second_bp => $m
				};

				# keep mapping in the same gene or mapping with high identity
				print STDERR "\nto filter mappings ...\t", join("\t", $m->{tpos}, $pm->{tpos}, abs($m->{tpos} - $pm->{tpos}), $min_dist, $m->{percent}), "\n" if($debug);
				my $dist = abs($m->{tpos} - $pm->{tpos});
				next if($min_dist < $self->{MIN_FS_DIST} && $dist > $min_dist);
				#next if($dist < $self->{MIN_FS_DIST} && $dist > $min_dist);

				print STDERR "push \@tmp_SVs, $tmp_SV, \tpm->{matches}", $pm->{matches}, "\tm->{matches}", $m->{matches}, "\n" if($debug);
				print STDERR "mapping locations: ", join("\t", $tmp_SV->{first_bp}->{tstart},$tmp_SV->{first_bp}->{tend}, $tmp_SV->{second_bp}->{tstart}, $tmp_SV->{second_bp}->{tend}), "\n" if($debug);
				my $updated_SV = $self->calc_repeat_score(-PSL => $psl_file, -SV => $tmp_SV, -RESULT => \@results);
				print STDERR "push \@rtn, $tmp_SV, \tpm->{matches}", $updated_SV->{first_bp}->{matches}, "\tm->{matches}", $updated_SV->{second_bp}->{matches}, "\n" if($debug);
				print STDERR "mapping locations: ", join("\t", $updated_SV->{first_bp}->{tstart},$updated_SV->{first_bp}->{tend}, $updated_SV->{second_bp}->{tstart}, $updated_SV->{second_bp}->{tend}), "\n" if($debug);
				#my $out_string = join("\t", $pm->{ort}, $pm->{tname}, $pm->{tstart}, $pm->{tend}, $pm->{qstart}, $pm->{qend}, $pm->{qstrand}, $pm->{matches}, $pm->{percent}, $pm->{repeat}, $qname, $qseq, $m->{ort}, $m->{tname}, $m->{tstart}, $m->{tend}, $m->{qstart}, $m->{qend}, $m->{qstrand}, $m->{matches}, $m->{percent}, $m->{repeat}); 
				print STDERR "$qname internal mapped\n" if($debug);
				push @rtn, $updated_SV;
				#push @rtn, $out_string;
				#push @tmp_SVs, $updated_SV;
			}
		}
	}
	return @rtn;
}

sub overhang_remapping {
	my $self = shift;
	my %param = @_;
	my $PSL_file = $param{-QUERY} . ".psl";
	my $options = $param{-OPTIONS} || $self->{OPTIONS};
	my $pm = $param{-SC_PM};
	my $sc_chr = $param{-scChr};
	my $sc_site = $param{-scSite};
	my $blat_prefix = join(" ", ($self->{PRG}, $self->{BIT2_DIR}));
	my $tentative_anchor = $param{-anchorBP} || "0:0";

	my $debug = 0;
	print STDERR "\n==== overhang_remapping ====\n" if($debug);
	#my ($PSL_file, $tentative_anchor, $pm, $blat_prefix, $options, $sc_chr, $sc_site) = @_;
	my $bp_1 = join("\t", $pm->{ort}, $pm->{tname}, $pm->{tstart},$pm->{tend},$pm->{qstart},$pm->{qend},$pm->{qstrand}, $pm->{matches}, $pm->{percent}, $pm->{qname}, $pm->{qseq});
	my ($ort, $tchr, $tstart, $tend, $qstart, $qend, $qstrand, $n_matches, $percent, $qname, $qseq) = split("\t", $bp_1);
	my $pm_tpos = ($qstrand*$ort < 0) ? $tstart : $tend;
	print STDERR "$bp_1\noverhang_remapping...\n>qseq\n$qseq\n" if($debug);

	my $contig_file = substr $PSL_file, 0, -4;
	$contig_file .= '.overhang';
	my $unsorted_psl = $contig_file.".unsorted.psl";
	my $psl_file = $contig_file.".psl";
	my ($tentative_anchor_chr, $tentative_anchor_BP) = split(/:/, $tentative_anchor);

	my $over_hang_seq = $pm->{overhang_seq};
	open(hFo, ">$contig_file");
	print STDERR ">overhang\n$over_hang_seq\n" if($debug);
	print hFo ">overhang\n$over_hang_seq\n";
	close(hFo);

	my $test = system(join(" ", ($blat_prefix, $contig_file, $unsorted_psl, $options)));
	for(my $i=0; $i<10 && $test!=0; $i++){
		`sleep 3m`;
		print STDERR "failed and resubmiting...\n";
		$test = system(join(" ", ($blat_prefix, $contig_file, $unsorted_psl, $options)));
	}
	croak "Please check BLAT server is correctly configured or running.\n" if($test != 0);
	print STDERR "test=$test\t", join(" ", ($blat_prefix, $contig_file, $unsorted_psl, $options)), "\n" if($debug);

	return unless(-s $unsorted_psl);
	`sort -k 10,10d -k 14,14d -k 1,1nr $unsorted_psl -o $psl_file`;
	if ($?){
		my $err = $!;
		print STDERR "Error sorting blat output: $err\n"; 
		exit 22;
	}

	#print "sc site is $scSite\n";
	my ($max_length, $max_percent, $total_matches) = (0, 0);
	my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	my @rtn; # to return the nearest mapping if multiple local mappings
	my $bp_dist = $self->{MIN_FS_DIST}; # to return the nearest mapping if multiple local mappings
	#my $locally_mapped = 0;
	while(my $result = $parser->next_result) {
		while( my $hit = $result->next_hit ) {
			while( my $hsp = $hit->next_hsp) {
				my ($n_matches2) = $hsp->matches;
				#print "n_matches2: $n_matches2\n";
				next if($n_matches2 < $self->{MIN_HIT_LEN});
				my $m = {
					ort	=> ($pm->{ort} > 0) ? -1 : 1,
					tname	=> $hit->name,
					tstart	=> $hsp->start('hit'),
					tend	=> $hsp->end('hit'),
					qstart	=> $hsp->start('query'),
					qend	=> $hsp->end('query'),
					qstrand => $hsp->strand('query'),
					matches	=> $n_matches2,
					percent => $n_matches2/($hsp->end('query') - $hsp->start('query') + 1)
				};
				
				($m->{qstart}, $m->{qend}) = ($hsp->start('query')+$pm->{qend}, $hsp->end('query')+$pm->{qend}) if($pm->{ort} > 0);
				$m->{clip} = $m->{ort}*$m->{qstrand};
				$m->{qpos} = ($m->{ort} > 0) ? $m->{qend} : $m->{qstart};
				$m->{tpos} = ($m->{clip} > 0) ? $m->{tend} : $m->{tstart};

				print STDERR "chr: ", $m->{tname}, "\tm->{start}:", $m->{qstart}, "\tm->{end}: ", $m->{qend}, "\t", $m->{tstart}, "\tm->{end}: ", $m->{tend}, "\t", $m->{percent}, "\t", $n_matches2, "\n" if($debug);
				# to retrieve the best mapping
				next if ($m->{percent} < 0.9);
				$total_matches += $n_matches2;

				#prefer the mapping around the soft-clip region
				#print "if($tchr eq ", $hit->name, " && abs(", $hsp->start('hit'),"-$m_tpos)<100000)\n";
				if($tchr eq $hit->name){
					my $this_bp_dist = abs($hsp->start('hit') - $pm_tpos);
					$this_bp_dist = abs($hsp->end('hit') - $pm_tpos) if(abs($hsp->end('hit') - $pm_tpos) < $this_bp_dist);
					if($this_bp_dist < $self->{MIN_FS_DIST}){ # locally mapped
					#print STDERR "if(($ort > 0 && abs(", $m->{qstart}," - $qend) < 50) || ($ort < 0 && abs(", $m->{qend}," - $qstart) < 50))\n";
					next if($this_bp_dist > $bp_dist);
					$bp_dist = $this_bp_dist;
					if(($ort > 0 && abs($m->{qstart} - $qend) < 50) || ($ort < 0 && abs($m->{qend} - $qstart) < 50)){ #50bp gap

						$pm->{repeat} = 0; $m->{repeat} = 0;
						my $tmp_SV = {
							contig_name => $qname,
							junc_seq => $qseq,
							first_bp => $pm,
							second_bp => $m
						};
						@rtn = ();
						push @rtn, $tmp_SV if($n_matches2 >= $self->{MIN_HIT_LEN} && $m->{percent} >= $max_percent);
					}
				}}
				if($n_matches2 >= $max_length) { 
					$max_length = $n_matches2;
					$max_percent = ($m->{percent} > 0.8) ? 0.8 : $m->{percent};
				}
			}
		}
	}
	print STDERR "return null\n" if($debug && $max_length==0);
	return if($max_length==0);
	$total_matches = $max_percent if($total_matches==0);
	my $repeat = 1 - $max_length/$total_matches;

	# print out
#	open(hFo, ">$SV_file");

	print STDERR "max_percent:$max_percent\tmax_length:$max_length\tlocally mapped? ", scalar @rtn, "\n" if($debug);

	if(!@rtn){

	$parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	while(my $result = $parser->next_result) {
		my $segment_length = $result->query_length;
		while( my $hit = $result->next_hit ) {
			while( my $hsp = $hit->next_hsp) {
				my ($n_matches2) = $hsp->matches;
				next if($n_matches2 < $self->{MIN_HIT_LEN});

				my $m = {
					ort	=> -1*$pm->{ort},
					tname	=> $hit->name,
					tstart	=> $hsp->start('hit'),
					tend	=> $hsp->end('hit'),
					qstart	=> $hsp->start('query'),
					qend	=> $hsp->end('query'),
					qstrand => $hsp->strand('query'),
					matches	=> $n_matches2,
					percent => $n_matches2/($hsp->end('query') - $hsp->start('query') + 1)
				};

				#print STDERR "XXXXXX", join("\t", $m->{percent}, $m->{matches}, $segment_length, $m->{percent}), "\n";
				next if ($m->{percent} < 0.8 || ($m->{matches} < 0.8*$segment_length && $m->{percent} < 0.98));
				
				($m->{qstart}, $m->{qend}) = ($hsp->start('query')+$pm->{qend}, $hsp->end('query')+$pm->{qend}) if($pm->{ort} > 0);
				$m->{clip} = $m->{ort}*$m->{qstrand};
				$m->{qpos} = ($m->{ort} > 0) ? $m->{qend} : $m->{qstart};
				$m->{tpos} = ($m->{clip} > 0) ? $m->{tend} : $m->{tstart};

				if($n_matches2 == $max_length && $m->{percent} >= $max_percent){

				# filter based on tentative_anchor
				my ($anchor_chr, $anchor_bp);
				$anchor_chr = $hit->name;
				next if($tentative_anchor_BP > 0 && $anchor_chr ne $tentative_anchor_chr);
				$anchor_bp = $m->{qstrand} < 0 ? $hsp->start('hit'): $hsp->end('hit') if($m->{ort} > 0);
				$anchor_bp = $m->{qstrand} > 0? $hsp->start('hit'): $hsp->end('hit') if($m->{ort} < 0);
				next if($tentative_anchor_BP > 0 && abs($tentative_anchor_BP - $anchor_bp) > 3);

				$m->{repeat} = $repeat;
				my $tmp_SV = {
					contig_name => $qname,
					junc_seq => $qseq,
					first_bp => $pm,
					second_bp => $m
				};
				my $out_string = join("\t", $pm->{ort}, $pm->{tname}, $pm->{tstart}, $pm->{tend}, $pm->{qstart}, $pm->{qend}, $pm->{qstrand}, 
						 $pm->{matches}, $pm->{percent}, $pm->{repeat}, $qname, $qseq, $m->{ort}, $m->{tname}, $m->{tstart}, $m->{tend},
						 $m->{qstart}, $m->{qend}, $m->{qstrand}, $m->{matches}, $m->{percent}, $m->{repeat});
				print STDERR "... out_string: $out_string\n" if($debug);

				# return candidate SVs
				push @rtn, $tmp_SV;
				} #end if
			}
		}
	}}
	print STDERR "number of remapping: ", scalar @rtn, "\n" if($debug);
	#return @rtn_internal if(!@rtn_internal);
	#if(!@rtn_internal) {print "return \@rtn_internal\n"; return @rtn_internal;}
	return @rtn;
}

sub low_complexity{
	my $sequence = shift;
        my $max_single_nt = 0.8 * length($sequence);
        my $max_run_nt = 0.6 * length($sequence);

        return 1 if @{[$sequence =~ /(A)/g]} > $max_single_nt;
        return 1 if @{[$sequence =~ /(C)/g]} > $max_single_nt;
        return 1 if @{[$sequence =~ /(T)/g]} > $max_single_nt;
        return 1 if @{[$sequence =~ /(G)/g]} > $max_single_nt;
        #return 1 if $sequence =~ /(A{$max_run_nt,})/;

	my $mask_seq = $sequence;
	$mask_seq =~ s/((.+)\2{3,})/'N' x length $1/eg;
        return 1 if @{[$sequence =~ /(N)/g]} > $max_single_nt;
	return 1 if $mask_seq =~ /(N{$max_run_nt,})/;
	return 0;
}

sub calc_repeat_score {
	my $self = shift;
	my %param = @_;
	my $psl_file = $param{-PSL};
	my $mapping = $param{-SV};
	my @results = @{$param{-RESULT}};

	#to start calculate repeat score
	my $debug = 0;
	print STDERR "\n===\ncalculating repeat score ....\nPSL_file: $psl_file\n===\n" if($debug);
	my ($qname, $qseq, $bp1, $bp2) = ($mapping->{contig_name}, $mapping->{junc_seq}, $mapping->{first_bp}, $mapping->{second_bp});

	my ($lm, $rm) = ($bp1->{ort} > 0) ? ($bp1, $bp2) : ($bp2, $bp1);

	print join("\t", "qname, qseq, lm, rm = ", $qname, $qseq, $lm, $rm, $lm->{matches}, $rm->{matches}), "\n" if($debug);
	my $left_cutoff = ($lm->{matches} > 100)? $lm->{matches} - 10 : $lm->{matches}*0.9;
	print STDERR "left cutoff: ", $left_cutoff, "\n" if($debug);
	my $right_cutoff = ($rm->{matches} > 100)? $rm->{matches} - 10 : $rm->{matches}*0.9;
	print STDERR "right cutoff: ", $right_cutoff, "\n" if($debug);
	#my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	my $repeat=();
	#while( my $result = $parser->next_result ) { #foreach contig
	foreach my $result (@results) {
		$result->rewind;	
		print STDERR "result->query_name:", $result->query_name, "\tqname: ", $qname, "\n" if($debug);
		next if($result->query_name ne $qname);
		my ($left_matches, $right_matches) = (0, 0);
		while(my $hit = $result->next_hit) { #foreach chrom
			$hit->rewind;
			while( my $hsp = $hit->next_hsp) {
				my ($n_matches) = $hsp->matches;
				my $percent = $n_matches / ($hsp->end('query') - $hsp->start('query') + 1);
				next if($n_matches <= $self->{MIN_HIT_LEN} || $percent < 0.75);
				my $left = ($hsp->start('query') + $hsp->end('query') < $hit->query_length) ? 1 : 0;
				$left_matches += $n_matches if($left && $n_matches >= $left_cutoff);
				$right_matches += $n_matches if(!$left && $n_matches >= $right_cutoff);
			}
		}
	$left_matches = $lm->{matches} if($left_matches == 0);
	$right_matches = $rm->{matches} if($right_matches == 0);
	my $lr = 1 - $lm->{matches}/$left_matches;
	my $rr = 1 - $rm->{matches}/$right_matches;
	print STDERR "repeat->left: ", $lr, "\tleft_matches: $left_matches", "\n" if($debug);
	print STDERR "repeat->right: ", $rr, "\tright_matches: $right_matches", "\n" if($debug);
	$lm->{repeat} = 1 - $lm->{matches}/$left_matches;
	$rm->{repeat} = 1 - $rm->{matches}/$right_matches;
	last;
	}

	($bp1, $bp2) = ($bp1->{ort} > 0) ? ($lm, $rm) : ($rm, $lm);
	my $tmp_SV;
	$tmp_SV = {
		contig_name => $qname,
		junc_seq => $qseq,
		first_bp => $bp1,
		second_bp => $bp2
		};
	return $tmp_SV;
}

sub select_overhang_mapping {
	my $self = shift;
	my ($PSL_file, $tentative_anchor, $pm, @results) = @_;
	my ($tentative_anchor_chr, $tentative_anchor_BP) = split(/:/, $tentative_anchor);
	my $debug = 0;
	print STDERR "\n==== select_overhang_mapping ... ====\nPSL_file: $PSL_file\n" if($debug);
	print STDERR "tentative_anchor:$tentative_anchor\n" if($debug);
#	print join("\n", $PSL_file, $ctg, $ort, $tchr, $tstart, $tend, $qstart, $qend, $qstrand), "\n";
#	print "PSL file is $PSL_file\n";

	my $bp_1 = join("\t", $pm->{ort}, $pm->{tname}, $pm->{tstart},$pm->{tend},$pm->{qstart},$pm->{qend},$pm->{qstrand}, $pm->{matches}, $pm->{percent}, $pm->{qname}, $pm->{qseq});
	my ($aaa, $sc_chr, $tstart, $tend, $qstart, $qend, $qstrand, $n_matches, $percent, $ctg, $qseq) = split("\t", $bp_1);
	my $over_hang_len = length($pm->{overhang_seq});
	print STDERR "bp_1: $bp_1\toverhang_len: $over_hang_len\n" if($debug);
	#print "ort in select_overhang_mapping is $ort\n";
	#print "sc site is $scSite\n";
	#print STDERR "pm->ort: ",  $pm->{ort}, "\n";

	my @rtn;
	#my $parser = Bio::SearchIO->new( -file => $PSL_file, -format => 'psl');
	my $contig_file = substr $PSL_file, 0, -4;
	my ($max_length, $max_percent) = (0, 0);
	my $total_matches = 0;
	#while(my $result = $parser->next_result) {
	foreach my $result (@results) {
		$result->rewind;		
		my $qname = $result->query_name;
		#print "qname: $qname\t ctg: $ctg\n" if($debug);
		next unless($qname eq $ctg);
		while( my $hit = $result->next_hit ) {
			$hit->rewind;
			while( my $hsp = $hit->next_hsp) {
				my ($n_matches_2) = $hsp->matches;
				next if($n_matches_2 < $self->{MIN_HIT_LEN});
				my $percent_2 = $n_matches_2/($hsp->end('query') - $hsp->start('query') + 1);
				my $qstrand_2 = $hsp->strand('query');
				#print STDERR join("\t", $n_matches_2, $percent_2, $qstrand_2), "\n" if($debug);
				my $new_ort = ($hsp->start('query') + $hsp->end('query') > 2*$pm->{qpos}) ? -1 : 1;
				next if($pm->{ort} == $new_ort);
				# to find the best mapping
				#print STDERR "ort: ", $pm->{ort}, "\tnew_qend: ", $hsp->end('query'), "\tqstart: ", $qstart, "\t", join("\t", $n_matches_2, $percent_2, $qstrand_2), "\n" if($debug);
				if(($pm->{ort} > 0 && $hsp->start('query') > $qend - 15 && $hsp->start('query') < $qend + 50) || 
				($pm->{ort} < 0 && $hsp->end('query') < $qstart + 15 && $hsp->end('query') > $qstart - 50)){

					if($n_matches_2 >= $max_length){ 
						$max_length = ($n_matches_2 < $over_hang_len) ? $n_matches_2 : $over_hang_len;
						$max_percent = ($percent_2 > 0.95) ? 0.95 : $percent_2;
					}
				}#end if
			}
		}
	}
	print STDERR "return null\n" if($debug && ($max_length==0 || $max_percent<0.9));
	return if($max_length==0 || $max_percent<0.9);
	$total_matches = $max_length if($total_matches==0);
	my $repeat = 1 - $max_length/$total_matches;

	###
	#
	#
	#msx_matches is not correct, should consider ort info
	#            
	print STDERR "max_percent:$max_percent\tmax_length:$max_length\n" if($debug);
	if(!@rtn){
	#$parser = Bio::SearchIO->new( -file => $PSL_file, -format => 'psl');
	#while( my $result = $parser->next_result ) {
	foreach my $result (@results) {
		$result->rewind;
		my ($qname, $contig_len) = ($result->query_name, $result->query_length);
		next unless($qname eq $ctg);
		print STDERR "qname: $qname\tctg: $ctg\n" if($debug);
		while( my $hit = $result->next_hit ) {
			$hit->rewind;
			my $tchr = $hit->name;
			my $l_tchr = $tchr;
			my $l_sc_chr = $sc_chr; 
			$l_tchr =~ s/^chr//; 
			$l_sc_chr =~ s/^chr//;
			next if($l_tchr eq $l_sc_chr);
			while( my $hsp = $hit->next_hsp) {
				my ($n_matches_2) = $hsp->matches;
				#print STDERR join("\t", $hsp->start('query'), $self->{MIN_HIT_LEN}, $contig_len, $hsp->end('query')), "\n";# || $percent < 0.9);
				#next if($pm->{ort} == 1 && $hsp->start('query') > $self->{MIN_HIT_LEN} && $contig_len - $hsp->end('query') > $self->{MIN_HIT_LEN});# || $percent < 0.9);
				next if($n_matches_2 < $self->{MIN_HIT_LEN});
				my $m = {
					tname	=> $hit->name,
					tstart	=> $hsp->start('hit'),
					tend	=> $hsp->end('hit'),
					qstart	=> $hsp->start('query'),
					qend	=> $hsp->end('query'),
					qstrand => $hsp->strand('query'),
					matches	=> $n_matches_2,
					percent => $n_matches_2/($hsp->end('query') - $hsp->start('query') + 1),
				};
				next if($m->{matches} < $max_length - 10 || $m->{percent} < 0.9);
				$m->{ort} = ($hsp->start('query') + $hsp->end('query') > $contig_len)? -1 : 1;
				my $new_ort = ($hsp->start('query') + $hsp->end('query') > 2*$pm->{qpos}) ? -1 : 1;
				next if($pm->{ort} == $m->{ort});
				$m->{clip} = $m->{ort}*$m->{qstrand};
				$m->{qpos} = ($m->{ort} > 0) ? $m->{qend} : $m->{qstart};
				$m->{tpos} = ($m->{clip} > 0) ? $m->{tend} : $m->{tstart};

				print STDERR join("\t", "qstart:", $hsp->start('query'), "qend:", $hsp->end('query'), "contig_len:", $contig_len, "ort:", $m->{ort}, $pm->{ort}), "\n" if($debug);
				my $overlap = ($pm->{ort} > 0) ? $qend - $hsp->start('query') :  $hsp->end('query') - $qstart;
				my $gap = ($pm->{ort} > 0) ? $m->{qstart} - $pm->{qend} : $pm->{qstart} - $m->{qend};
				next if($overlap > 15 || $gap > 50);
				print STDERR "overlap: $overlap\tgap:$gap\tn_matches: $n_matches_2\tmax_percent: $max_percent\tmax_length:$max_length\n" if($debug);

				# to retrieve the best mapping
				print STDERR "found the other end at\t", "tstart, tend, tpos, qstart, qend, n_matches, percent, qstart, qend: \n", join(", ", $m->{tstart}, $m->{tend}, $m->{tpos}, $m->{qstart}, $pm->{qend}, $n_matches, $percent, $hsp->start('query'), $hsp->end('query')), "\n\n"  
				if($debug && $m->{matches} >= $max_length - 15 && $m->{percent} >= $max_percent);

				# filter based on tentative_anchor
				next if($tentative_anchor_BP > 0 && $hit->name ne $tentative_anchor_chr);
				my $anchor_bp = $m->{qstrand} < 0 ? $hsp->start('hit'): $hsp->end('hit') if($m->{ort} > 0);
				$anchor_bp = $m->{qstrand} > 0 ? $hsp->start('hit'): $hsp->end('hit') if($m->{ort} < 0);
				#print STDERR "next if($tentative_anchor_BP > 0 && abs($tentative_anchor_BP - $anchor_bp) > 3)\n";
				next if($tentative_anchor_BP > 0 && abs($tentative_anchor_BP - $anchor_bp) > 15);

				#my $bp_2 = join("\t", $ort_2, $hit->name, $hsp->start('hit'), $hsp->end('hit'), $hsp->start('query'), $hsp->end('query'), $qstrand_2, $n_matches_2, $percent_2); 
				my $tmp_SV = {
					contig_name => $qname,
					junc_seq => $qseq,
					first_bp => $pm,
					second_bp => $m
				};
				next if($pm->{matches} < $self->{MIN_HIT_LEN} || $m->{matches} < $self->{MIN_HIT_LEN});
				my $updated_SV = $self->calc_repeat_score(-PSL=>$PSL_file, -SV=>$tmp_SV, -RESULT => \@results);
				my $out_string = join("\t", $pm->{ort}, $pm->{tname}, $pm->{tstart}, $pm->{tend}, $pm->{qstart}, $pm->{qend}, $pm->{qstrand}, 
						 $pm->{matches}, $pm->{percent}, $pm->{repeat}, $qname, $qseq, $m->{ort}, $m->{tname}, $m->{tstart}, 
						 $m->{tend}, $m->{qstart}, $m->{qend}, $m->{qstrand}, $m->{matches}, $m->{percent}, $m->{repeat}); 
				# return candidate SVs
				print STDERR "out_string:  $out_string\n" if($debug && $m->{matches} >= $max_length && $m->{percent} >= $max_percent);
				#print STDERR "m->{matches}: ", $m->{matches}, "\tmax_length: $max_length", "\tm->{percent}: ", $m->{percent}, "\tmax_percent: ", $max_percent, "\n" if($debug);
				push @rtn, $tmp_SV;
				#return @rtn if (scalar @rtn == 3);
				#push @rtn, $tmp_SV if($m->{matches} >= $max_length - 15 && $m->{percent} >= $max_percent);
			}
		}
	}}
	return @rtn;
}

sub select_sc_contig {
	my $self = shift;
	my %param = @_;
	my $contig_file = $param{-QUERY};
	my $read_len = $param{-READ_LEN};
	my $sc_chr = $param{-scChr};
	my $bad_contigs = $param{-BAD};
	my $scSite = $param{-scSite};
	my $tentative_anchor = $param{-anchorBP} || "0:0";
	my $clip = $param{-CLIP};
	my @results = @{$param{-RESULT}};

	my $debug = 0;
	my $psl_file = $contig_file.".psl";
	print STDERR "\n==== to find SC contigs at $sc_chr:$scSite ====\nPSL_file: $psl_file\nclip: $clip\n" if($debug);

	my %sc_pms = (); #partial mappings at soft-clip site
	my $contig_seqs = read_fa_file($contig_file);	
	my @seq_names = keys %{$contig_seqs};
	my %max_length = ();

	my %bad_contigs = %{$bad_contigs}; # to find fully mapped contigs
	#my $parser = Bio::SearchIO->new( -file => $psl_file, -format => 'psl');
	#while( my $result = $parser->next_result ) { #foreach contig
	foreach my $result (@results) {
		$result->rewind;
		#$n_contigs+=1;
		my ($qname, $contig_len) = ($result->query_name, $result->query_length);
		# If the contig was already called "bad", skip it
		next if(exists($bad_contigs{$qname}));
		my $qseq = $contig_seqs->{$qname};
		my $pm;
		my $total_length = 0;
		while(my $hit = $result->next_hit) { #foreach chrom
			$hit->rewind;
			my (@left_mappings, @right_mappings);
			my $over_hang_seq = '';
			my $tchr = $hit->name;
			
			print STDERR "\n$qname\tsc_chr:$sc_chr\ttchr:$tchr\tsc_site: $scSite\tclip: $clip\n" if($debug);
			while(my $hsp = $hit->next_hsp) {
				# Number of identical bases
				my ($n_matches) = $hsp->matches;
				# Number of mismatched bases
				my ($n_mis_matches) = $hsp->mismatches;
				my ($tstart, $tend, $qstart, $qend, $qstrand) = ($hsp->start('hit'), $hsp->end('hit'), $hsp->start('query'), $hsp->end('query'));
				# If the length of the match is less than MIN_HIT_LEN, skip it.
				next if($qend - $qstart < $self->{MIN_HIT_LEN});
				# Number of matches - number of mismatches / alignment length
				my $identity =  ($n_matches - $n_mis_matches)/($qend - $qstart + 1);
				#print STDERR "scSite, clip, tchr, tstart, tend, qstart, qend, qstrand, n_matches\n", join("\t", $scSite, $clip, $tchr, $tstart, $tend, $qstart, $qend, $qstrand, $n_matches), "\n" if($debug);
				next if($qstart < $self->{MIN_HIT_LEN} && $contig_len - $qend < $self->{MIN_HIT_LEN} && $identity > 0.9); # to remove fully mapped contigs
				# Sum the number of matches over all pairs and all chromosomes
				$total_length += $n_matches;
				# Trim 'chr' prefixes before comparison
				my $l_sc_chr = $sc_chr;
				$l_sc_chr =~ s/^chr//;
				my $l_tchr = $tchr; 
				$l_tchr =~ s/^chr//;
				last if($l_sc_chr ne $l_tchr);
				
				# need to trim the wrongly mapped region.
				my @tblocks = @{$hsp->gap_blocks('hit')};
				my @qblocks = @{$hsp->gap_blocks('query')};
				my $trim_len = 0;
				if($clip > 0 && $tend > $scSite){
					# Loop over each block in the alignment, starting at the end.
					for(my $i=$#tblocks; $i>=0; $i--) {
						# Get the block in the reference 
						my $bl = $tblocks[$i];
						print STDERR join("\t", "right clipped", $n_matches, $qstart, $qend, $bl->[0], $bl->[1], $scSite), "\n" if($debug);
						# If the block start position is past the sc site
						# Subtract the block length from the number of matches
						# And add it to the trimmed length
						if($bl->[0] > $scSite){
							$n_matches -= $bl->[1];
							$trim_len += $bl->[1];
							next;
						}
						# End position of block minus the sc site location
						# Number of bases between the end and the sc site
						my $over_hang = ($bl->[0] + $bl->[1] - $scSite);
						# The block in the query
						my $qbl = $qblocks[$i];
						# If on the + strand, trim from the end
						if($hsp->strand('query') == 1){
							# Adjust the end of the query match to the end of this block, minus the number of bases past the sc site
							$qend = $qbl->[0] + $qbl->[1] - $over_hang;
						}
						else{ # If on the - strand, trim from the beginning
							# Adjust the start of the query match to the beginning of the block, minus the length of the block, plus the number of bases past the sc site
							$qstart = $qbl->[0] - $qbl->[1] + $over_hang;
						}
						print STDERR "n_matches: $n_matches\tblk: ", $qbl->[1], "\n" if($debug);
						# Remove the overhang length from the number of matches
						$n_matches -= $over_hang;
						# Add the overhang to the number of bases trimmed
						$trim_len += $over_hang;
						print STDERR "right clipped n_matches: $n_matches\n" if($debug);
						last;
					}
					# Set the end position in the reference to the sc site
					$tend = $scSite; 
				}

				if($clip < 0 && $tstart < $scSite){ # left clipped; to trim the micro homolog
					# Loop over each block in the alignment.
					for(my $i=0; $i<=$#tblocks; $i++) {
						# Get the block in the reference and query
						my ($bl, $qbl) = ($tblocks[$i], $qblocks[$i]);
						print STDERR join("\t", "left-clipped", "nmatches: $n_matches", "qstart: $qstart", "qend: $qend", "qbl->[0]:", $qbl->[0],
						"qbl->[1]: ", $qbl->[1], "bl->[0]: ", $bl->[0], "bl->[1]: ", $bl->[1], "scSite: ", $scSite, $qseq), "\n" if($debug);
						# If the block end position is before the sc site
						# Subtract the block length from the number of matches
						# And add it to the trimmed length						
						if($bl->[0] +  $bl->[1] < $scSite){
							$n_matches -= $bl->[1];
							$trim_len += $bl->[1];
							next;
						}
						# Number of bases between the start position and the sc site
						my $over_hang = $scSite - $bl->[0];
						print STDERR "over_hang: $over_hang\n" if($debug);
						# Remove the overhang length from the number of matches
						$n_matches -= $over_hang;
						# Add the overhang to the number of bases trimmed
						$trim_len += $over_hang;
						print STDERR "n_matches: $n_matches\tblk: ", $qbl->[1], "\t", $bl->[1], , $trim_len, "\n" if($debug);
						print STDERR "left clipped n_matches: $n_matches\n" if($debug);
						last;
					}
					# Set the start position in the reference to the sc site
					$tstart = $scSite; 
				}

				print STDERR "........ start:",$tstart,"\tend:", $tend, "\tqstart:", $qstart,"\t", "\tqend:", $qend, "\n" if($debug); 
				# If the alignment length is less than MIN_HIT_LEN
				# Or the remaining number of matched bases after trimming is less than MIN_HIT_LEN
				next if($qend - $qstart < $self->{MIN_HIT_LEN} || $n_matches < $self->{MIN_HIT_LEN});

				# if distance in the reference alignment is more than 50bp from the soft clip site, then not sc contig
				# Or if the start in the reference is less than MIN_HIT_LEN from the soft clip site, then not sc contig
				next if ($clip > 0 && ($scSite - $tend > 50 || $tstart > $scSite - $self->{MIN_HIT_LEN})); 
				#print STDERR "next if ($clip < 0 && ($tstart - $scSite > 50 || $tend < $scSite + ", $self->{MIN_HIT_LEN}, "))\n";
				next if ($clip < 0 && ($tstart - $scSite > 50 || $tend < $scSite + $self->{MIN_HIT_LEN}));
				my $qseq = $contig_seqs->{$qname};

				if($clip * $hsp->strand('query') > 0){
					$qend = $hsp->start('query') + $n_matches;
				}
				else{
					$qstart = $hsp->end('query') - $n_matches;
				}
				# The percentage of the alignment that is a match
				my $percent = $n_matches / ($qend - $qstart + 1);
				print STDERR "start:",$tstart,"\tend:", $tend, "\tqstart:", $qstart,"\t", "\tqend:", $qend, "\tpercent: ", $percent,"\n" if($debug); 
				# If the match is more than 80%
				if($percent >= 0.8){
				   my $qstrand = $hsp->strand('query');
				   my $ort = ($qstart + $qend > $hit->query_length)? -1 : 1; # right part is in the sc region

				   print STDERR "$ort*$qstrand != $clip\n" if($debug);

				# to test low complexity
				my ($over_hang_seq, $junction_seq);
				
				# Get the sequence for the overhang portion of the alignment
				$over_hang_seq = substr $qseq, 0, $qstart + 1 if($ort < 0);
				$over_hang_seq = substr $qseq, $qend - 1 if($ort > 0);
				my $over_hang_len = length($over_hang_seq);
		
				# If the overhang sequence is longer than 25bp
				# Take 25bp before the start or after the end depending on orientation
				if(length($over_hang_seq) > 25){
					$junction_seq = substr $qseq, $qstart - 24, 25 if($ort < 0);
					$junction_seq = substr $qseq, $qend - 1, 25 if($ort > 0);
				}
				else{
					# If less than 25bp, use the overhang sequence as the junciton sequence
					$junction_seq = $over_hang_seq;
				}
				print STDERR "over_hang_seq: $over_hang_seq\njunction_seq: $junction_seq\nlow complexity? ", low_complexity($junction_seq), "\n" if($debug);
				my ($qpos, $tpos);
				$qpos = ($ort > 0)? $qend : $qstart;
				$tpos = ($clip > 0) ? $tend: $tstart;

				# Store the partial mapping
				# Check low complexity: Is > 80% of the sequence a single nucleotide character? Is > 60% of the sequence a run of a single character?
				$pm = {
					    ort => $ort,
					    tpos => $tpos,
					    qpos => $qpos,
					    tname => $hit->name,
					    tstart => $tstart,
					    tend => $tend,
					    qstart => $qstart,
					    qend => $qend,
					    qstrand => $qstrand,
					    matches => $n_matches,
					    percent => $percent,
					    qname => $qname,
					    qseq => $qseq,
					    overhang_seq => $over_hang_seq,
					    low_complexity => low_complexity($junction_seq)
					  };
				#push @partial_mappings, $pm;
				$sc_pms{$qname} = $pm;
				print STDERR "found SC contig:\t", join("\t", $qname, $scSite, $pm->{tname}, $pm->{tstart}, $pm->{tend}, $pm->{tpos}, $pm->{ort}), "\t", $pm->{qseq}, "\n" if($debug);
				last;
				}
			}	
			$hit->rewind;
		}
		next unless(exists($sc_pms{$qname}));
		# compute repetitive fraction as 1 - fraction of sequence that is a match
		$sc_pms{$qname}->{repeat} = 1 - $sc_pms{$qname}->{matches}/$total_length;
	}
	return \%sc_pms;
}

sub select_target {
	my $self = shift;
	my $file = shift;
	my $scSite = shift;
	#print "sc site is $scSite\n";
	my %targets;
	my $parser = Bio::SearchIO->new( -file => $file, -format => 'psl');

	my %selected = ();
	my %mapped = ();
	while( my $result = $parser->next_result ) {
		my $qname = $result->query_name;
		$result->sort_hits(sub {$Bio::Search::Result::ResultI::b -> matches('id') <=> 
		            $Bio::Search::Result::ResultI::a ->matches('id')});
#		my $perfect_only;
		while( my $hit = $result->next_hit ) {
			while( my $hsp = $hit->next_hsp) {
				# fully mapped
				next if(exists($mapped{$qname}));
				$mapped{$qname} = 1 if($hsp->start('query') <= 25 && $hit->query_length - $hsp->end('query') <= 25);

				$selected{$qname} = 1  if(abs($hsp->start('hit') - $scSite) <= 15); # right part is in the sc region
				$selected{$qname} = -1 if(abs($hsp->end('hit') - $scSite) <= 15); # left part is in sc region

			}	
		}
	}

	return undef if(!keys %selected); 
	my @contigs = keys %selected; 
	$parser = Bio::SearchIO->new( -file => $file, -format => 'psl');
	while( my $result = $parser->next_result ) {
		my $qname = $result->query_name;
		next if(exists($mapped{$qname}));
		next unless(exists($selected{$qname}));
		$targets{$qname} = [];
		$result->sort_hits(sub {$Bio::Search::Result::ResultI::b -> matches('id') <=> 
		            $Bio::Search::Result::ResultI::a ->matches('id')});
		my $n_hits = 0;
		my $max_score = 0;
#		my $perfect_only;
		while( my $hit = $result->next_hit ) {
			while( my $hsp = $hit->next_hsp) {

				my ($n_matches) = $hsp->matches;
				#last if($max_score - $n_matches > $self->{MAX_SCORE_DIFF});
				#last if($max_score - $n_matches > $self->{MAX_SCORE_DIFF});
				#last if($perfect_only && $hit->query_length != $n_matches);
				my @blocks;
				foreach my $bl (@{$hsp->gap_blocks('hit')}) {
					push @blocks, [$bl->[0], $bl->[0] + $bl->[1]];
				}
				#push @{$targets{$qname}}, {
				#next if($hsp->start('query') > 25 && $hit->query_length - $hsp->end('query') > 25);
				my $align_part = ($hsp->start('query') <= 25)? 'left': 'right';
				print "align part: $align_part\n";
				#my $align_part = 'left' if($hsp->start('query') <= 25);
				#$align_part = 'right' if($hit->query_length - $hsp->end('query') <= 25);

				push @{$targets{$align_part}{$qname}}, {
					tchr	=> $hit->name,
					tstart	=> $hsp->start('hit'),
					tend	=> $hsp->end('hit'),
					qname	=> $qname,
					qstart	=> $hsp->start('query'),
					qend	=> $hsp->end('query'),
					qstrand => $hsp->strand('query') == 1 ? '+' : '-',
					matches	=> $n_matches,
					blocks	=> \@blocks,
					percent => $n_matches/($hsp->end('query') - $hsp->start('query') + 1),
					perfect => $hit->query_length == $n_matches ? 1 : 0,
				};
				#$perfect_only = 1 if($hit->query_length == $n_matches);
				$max_score = $n_matches if($max_score < $n_matches);
				$n_hits++;
			}
			$hit->rewind;
			last if($n_hits >= $self->{MAX_NUM_HITS});
		}
	}
	return \%targets;
}

package Aligner;
use strict;
use Carp;
use English;
use Bio::SearchIO;
use Bio::SeqIO;
use base qw(CiceroExtToolsI);

sub new {
	my ($class, @args) = @_;
	my $self = $class->SUPER::new(@args);
	$self->{PRG} = "blat" if(!$self->{PRG});
	$self->{OPTIONS} = "-stepSize=5 -repMatch=2253 -minScore=0 -minIdentity=0 -out=psl -nohead" 
	#$self->{OPTIONS} = "-tileSize=9 -stepSize=1 -out=psl -nohead -minScore=15" 
		if(!$self->{OPTIONS});
	return $self;
}

# return best hit for each query reads
sub run {
	my $self = shift;
	my %param = @_;
	croak "Missing TARGET parameter for $self->{PRG}" if(!$param{-TARGET});
	croak "Missing QUERY parameter for $self->{PRG}" if(!$param{-QUERY});
	my $output = $param{-OUTPUT} || $param{-QUERY} . ".psl";
	my $opt = $self->{OPTIONS} . " -maxIntron=1 ";
	my $ret = system( join(" ", ($self->{PRG}, $param{-TARGET}, $param{-QUERY}, $output, $opt)));
	if ($ret){
		my $err = $!;
		print STDERR "Error running aligner: $err\n"; 
		exit 23;
	}
	my $rtn = _find_best_hit($output);
	if( scalar(keys(%{$rtn})) > 0) {
		return $output if($param{-FILE});
		return $rtn;
	}
	$opt = $self->{OPTIONS} . " -fastMap ";
	my $ret = system( join(" ", ($self->{PRG}, $param{-TARGET}, $param{-QUERY}, $output, $opt)));
	if ($ret){
		my $err = $!;
		print STDERR "Error running aligner: $err\n"; 
		exit 24;
	}
	return $output if($param{-FILE});
	return _find_best_hit($output);
}

sub _find_best_hit {
	my $file = shift;
	my $parser = Bio::SearchIO->new( -file => $file, -format => 'psl');
	my %best_hit;
	while( my $result = $parser->next_result ) {
		$result->sort_hits(sub {$Bio::Search::Result::ResultI::b -> matches('id') <=> 
		            $Bio::Search::Result::ResultI::a ->matches('id')});		
		my $hit = $result->next_hit; # the best hit
		my $hsp = $hit->next_hsp;
		$best_hit{$result->query_name} = $hit;
		$hit->rewind;
	}
	return \%best_hit;
}

1;

=head1 LICENCE AND COPYRIGHT
Copyright 2019 St. Jude Children's Research Hospital 

Licensed under a modified version of the Apache License, Version 2.0
(the "License") for academic research use only; you may not use this
file except in compliance with the License. To inquire about commercial
use, please contact the St. Jude Office of Technology Licensing at
scott.elmer@stjude.org.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

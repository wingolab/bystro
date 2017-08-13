use 5.10.0;
use strict;
use warnings;
package Seq::Tracks::Vcf::Build;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class Seq::Tracks::Vcf::Build
  Takes a VCF file, runs it through a vcf pre-processor to get it into 
  our internal annotation format, and then uses the info field to build a database

=cut

# TODO: better error handling in the vcf pre-processor
# TODO: Support fields delimited by something other than just , for Number=A
# TODO: Move opening of vcf to Seq::Input::Vcf
# TODO: Be more explicit with naming of indices from the intermediate annotation output
# (such as vcfAltIdx = 4, rather than using 4 itself)

# Note ALT field is required, if not found will be appended
use Mouse 2;

use namespace::autoclean;
use List::MoreUtils qw/firstidx/;
use Parallel::ForkManager;
use Scalar::Util qw/looks_like_number/;
use Seq::Output::Delimiters;
use Seq::Tracks::Base::Types;
use Scalar::Util qw/looks_like_number/;

use DDP;

extends 'Seq::Tracks::Build';

with 'Seq::Output::Fields';

# We assume sparse tracks have at least one feature; can remove this requirement
# But will need to update makeMergeFunc to not assume an array of values (at least one key => value)
has '+features' => (required => 1);

has vcfProcessor => (is => 'ro', isa => 'Str', required => 1, default => 'bystro-vcf');

state $converter = Seq::Tracks::Base::Types->new();

# name followed by index in the intermediate snp file
# QUAL and FILTER not yet implemented
# We also allow any fields output by the vcf professor (except info and the related alleleIdx)
state $vcfFeatures = {
  chrom => 0, pos => 1, type => 2, ref => 3, alt => 4, trTv => 5,
  homozygotes => 6, heterozygotes => 7, missingGenos => 8, id => 9,
  qual => undef, filter => undef};

# We can use before BUILD to make any needed modifications to $self->features
# before those features' indices are stored in the db in Seq::Base
before 'BUILD' => sub {};

sub BUILD {
  my $self = shift;

  my $features = $self->features;

  if(!@{$features}) {
    die "VCF build requires INFO features";
  }

  my %featuresMap;
  for(my $i = 0; $i < @{$features}; $i++) {
    $featuresMap{lc($features->[$i])} = $i;
  }

  my %fieldMap = map{ lc($_) => $self->fieldMap->{$_} } keys %{$self->fieldMap};

  my %visitedVcfFeatures;
  my @headerFeatures;
  for my $vcfFeature (keys %$vcfFeatures) {
    my $idx;

    if($visitedVcfFeatures{$vcfFeature}) {
      die "Duplicate feature requested: $vcfFeature";
    }

    $visitedVcfFeatures{$vcfFeature} = 1;

    # Because VCF files are so flexible with feature definitions, it will be
    # difficult to tell if a certain feature just isn't present in a vcf file
    # Easier to make feature definition flexible, especially since one 
    # may correctly surmise that we read the VCF after transformation to intermediate
    # annotated format
    my $lcVcfFeature = lc($vcfFeature);

    if(defined $featuresMap{$lcVcfFeature}) {
      $idx = $featuresMap{$lcVcfFeature};
    } elsif(defined $fieldMap{$lcVcfFeature} && defined $featuresMap{$fieldMap{$lcVcfFeature}}) {
      $idx = $featuresMap{$fieldMap{$lcVcfFeature}};
    }

    # This $vcfFeature isn't requested by the user
    if(!defined $idx) {
      next;
    }

    # Some features are placeholders; catch these anyhow so we don't try to look
    # for them in the INFO field
    if(!defined $vcfFeatures->{$vcfFeature} && defined $idx) {
      die "Currently $vcfFeature is not allowed";
    }

    #Stores:
    #1) The feature naem (post-transformation)
    #2) The index in the intermedaite annotation file
    #3) The index in the database
    push @headerFeatures, [
      $self->features->[$idx], $vcfFeatures->{$vcfFeature},
      $self->getFieldDbName($self->features->[$idx])
    ];
  }

  # We could also force-add alt; would get properly inserted into db.
  # However, we would reduce confidence users had in the representation stated
  # in the YAML config
  if(!defined $visitedVcfFeatures{alt}) {
    die "alt (or ALT) field is required for vcf tracks, used to match input alleles";
  }

  $self->{_headerFeatures} = \@headerFeatures;

  my %reverseFieldMap = map { $self->fieldMap->{$_} => $_ } keys %{$self->fieldMap};

  my %infoFeatureNames;
  for my $feature (@{$self->features}) {
    my $originalName = $reverseFieldMap{$feature} || $feature;

    # skip the first few columns, don't allow ALT in INFO
    if(defined $visitedVcfFeatures{lc($originalName)}) {
      next;
    }

    $infoFeatureNames{$feature} = $originalName;
  }

  # TODO: prevent header features from overriding
  $self->{_infoFeatureNames} = \%infoFeatureNames;

  # Precalculate the field db names, for faster accesss
  # TODO: think about moving away from storing the "db name" in the database
  # We may just want to enforce no changs to the order of fields once
  # The db is created
  # It fails in too many ways; for instance if you remove a feature,
  # Then try to build again, it will crash, because expected array length
  # shorter than some of the remaining field indices stored in db, potentially
  my %fieldDbNames;

  for my $feature (@{$self->features}) {
    $fieldDbNames{$feature} = $self->getFieldDbName($feature);
  }

  $self->{_fieldDbNames} = \%fieldDbNames;
}

# has altName => (is => '')
sub buildTrack {
  my $self = shift;

  my $pm = Parallel::ForkManager->new($self->max_threads);

  my $outputter = Seq::Output::Delimiters->new();

  my $delim = $outputter->emptyFieldChar;

  # my $altIdx = $self->headerFeatures->{ALT};
  # my $idIdx = $self->headerFeatures->{ID};

  my $lastIdx = $#{$self->features};

  for my $file (@{$self->local_files}) {
    $self->log('info', $self->name . ": beginning building from $file");

    $pm->start($file) and next;
      my $echoProg = $self->isCompressedSingle($file) ? $self->gzip . ' -d -c' : 'cat';

      my $wantedChr;
      my $errPath = $file . ".build." . localtime() . ".log";

      my ($err, $vcfNameMap) = $self->_extractHeader($file);

      if($err) {
        # DB not open yet, no need to commit
        $pm->finish(255, \$err);
      }

      # Get an instance of the merge function that closes over $self
      # Note that tracking which positinos have been over-written will only work
      # if there is one chromosome per file, or if all chromosomes are in one file
      # At least until we share $madeIntoArray (in makeMergeFunc) between threads
      # Won't be an issue in Go
      my $mergeFunc = $self->makeMergeFunc();

       # Record which chromosomes were recorded for completionMeta
      my %visitedChrs;

      open(my $fh, '-|', "$echoProg $file | " . $self->vcfProcessor . " --emptyField $delim"
        . " --keepId --keepInfo");

      # p $self->headerFeatures;
      # my $keepId = $self->headerFeatures->{ID};
      # my $keepAlt = $self->headerFeatures->{ALT};

      # p $keepId;
      # p $keepAlt;
      # my ($chr, @fields, @sparseData, $start, $end);
      while ( my $line = $fh->getline() ) {
        # This is the annotation input first 7 lines, plus id, info
        my @fields = split '\t', $line;

        # TODO: check for wanted chr, insert into db
         # Transforms $chr if it's not prepended with a 'chr' or is 'chrMT' or 'MT'
          # # and checks against our list of wanted chromosomes
          # $chr = $self->normalizedWantedChr( $fields[ $reqIdxHref->{$self->chromField} ] );

          # if(!$chr || $chr ne $wantedChr) {
          #   if($self->chrPerFile) {
          #     # Because this is not an unusual occurance; there is only 1 chr wanted
          #     # and the function is called once for each chromoosome, we use debug
          #     # to reduce log clutter
          #     $self->log('debug', $self->name . "join track: chrs in file $file not wanted . Skipping");

          #     last FH_LOOP;
          #   }

          #   next FH_LOOP;
          # }

        my ($err, $data) = $self->_extractFeatures(\@fields, $vcfNameMap);

        say "here is what we would be entering";
        p $data;

        if($err) {
          #Commit, sync everything, including completion status, and release mmap
          $self->db->cleanUp();
          $pm->finish(255, \$err);
        }

        # $self->db->dbPatch($wantedChr, $self->dbName, $pos, \@sparseData, $mergeFunc);
      }

    $pm->finish();
  }

  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $fileName, undef, undef, $errRef) = @_;

    if($exitCode != 0) {
      my $err = $errRef ? "due to: $$errRef" : "due to an untimely demise";

      $self->log('fatal', $self->name . ": Failed to build $fileName $err");
      die $self->name . ": Failed to build $fileName $err";
    }

    $self->log('info', $self->name . ": completed building from $fileName");
  });

  $pm->wait_all_children;
}

sub _extractHeader {
  my $self = shift;
  my $file = shift;
  my $dieIfNotFound = shift;

  my $echoProg = $self->isCompressedSingle($file) ? $self->gzip . ' -d -c' : 'cat';

  open(my $fh, '-|', "$echoProg $file");

  my @header;
  while(<$fh>) {
    chomp;

    if(substr($_, 0, 1) eq '#') {
      push @header, $_;
      next;
    }

    last;
  }

  close $fh;

  my $idxOfInfo = -9;
  my $idx = -1;

  my %nameMap;

  # Flags may or may not be in the info field
  # To speed search, store these, and walk back to find our value
  my $flagCount = 0;
  for my $h (@header) {
    $idx++;

    if($h !~ /\#\#INFO=/) {
      next;
    }

    if($idxOfInfo == -9) {
      $idxOfInfo = $idx;
    }

    $h =~ /Number=([\w.]+)/;

    my $number = $1;

    $h =~ /Type=(\w+)/;

    my $type = $1;

    # Keep track of things that look like they could mess up INFO string order
    # Flag in particular seems often missing, so we'll do a linear search
    # From $idx - $idxOfInfo to +$flagCount
    if(looks_like_number($number)) {
      if($number == 0) {
         $flagCount++;
      }
    } elsif($number eq '.') {
      $flagCount++;
    }

    my $featIdx = -1;

    # TODO: if the flag item is the feature we're searching for do something
    # Not critial, but will have less efficient search
    # Requires precise spelling of the vcf feature
    # TODO: Die if don't find header for any requested feature
    FEATURE_LOOP: for my $feature (@{$self->features}) {
      if(!defined $self->{_infoFeatureNames}{$feature}) {
        next;
      }

      my $infoName = $self->{_infoFeatureNames}{$feature};

      if(index($h, "INFO\=\<ID\=$infoName,") > 0) {
        # my $vcfName = "$feature=";
        # In case Number and Type aren't adjacent to each other
        # $return[$featIdx] = [$number, $type];
        $nameMap{$infoName} = [$feature, $number, $type, $idx];
        last FEATURE_LOOP;
      }
    }
  }

  return (undef, \%nameMap);
}

sub _extractFeatures {
  my ($self, $fieldsAref, $vcfNameMap, $fieldDbNames) = @_;
  
  # vcfProcessor will split multiallelics, store the alleleIdx
  # my @infoFields = ;

  my @returnData;
  $#returnData = $#{$self->features};

  my $firstChars;

  my $warned;

  my $entry;
  my $found = 0;
  my $name;

  # $arr holds
  # 1) field name
  # 2) index in intermediate annotation
  # 3) index in database
  for my $arr (@{$self->{_headerFeatures}}) {
    $returnData[$arr->[2]] = $self->coerceFeatureType($arr->[0], $fieldsAref->[$arr->[1]]);
  }

  my $alleleIdx = $fieldsAref->[-2];

  for my $info (split ';', $fieldsAref->[-1]) {
    # If # found == scalar @{$self->features}
    if($found == @returnData) {
      last;
    }

    $entry = $vcfNameMap->{substr($info, 0, index($info, '='))};
    
    # p $entry;
    if(!$entry) {
      next;
    }

    $found++;

    my $val = substr($info, index($info, '=') + 1);

    # If NUMBER=A
    if($entry->[1] eq 'A') {
      my @vals = split ',', $val;

      if(@vals - 1 < $alleleIdx) {
        return ("Err: Number=A field has fewer values than alleles", undef);
      }

      $val = $vals[$alleleIdx];
    }

    # TODO: support non-scalar values
    # TODO: configure from either type specified in YAML, or from VCF Type=
    $returnData[$self->{_fieldDbNames}{$entry->[0]}] = $self->coerceFeatureType($entry->[0], $val);
  }

  return (undef, \@returnData);
}

__PACKAGE__->meta->make_immutable;
1;
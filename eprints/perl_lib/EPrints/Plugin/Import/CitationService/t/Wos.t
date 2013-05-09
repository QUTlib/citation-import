 #!/usr/bin/env perl
use lib qw(/opt/eprints3/perl_lib);
use lib qw(/opt/eprints3/archives/quteprints/cfg/plugins); # To do: make it work in any archive

use strict;
use warnings;

use Test::More;

BEGIN { use_ok( 'EPrints::Plugin::Import::CitationService::WoS' ); }

# Test DOIs
diag( "Test DOI checking" );

# Valid cases
ok( EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/SICI' ) );
ok( EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/(SICI)' ) );
ok( EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/(SICI)1097-4679(199711)53:7<657::AID-JCLP3>3.0.CO;2-F' ) );

# Invalid cases
ok( !EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/(SICI' ) );
ok( !EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/SICI)' ) );
ok( !EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/SICI1097-4679199711)53:7<657::AID-JCLP3>3.0.CO;2-F' ) );
ok( !EPrints::Plugin::Import::CitationService::WoS::_is_usable_doi( '10.1002/SICI1097-4679(19971153:7<657::AID-JCLP3>3.0.CO;2-F' ) );

# To do: Test various actual queries against the web service ...

done_testing();


1;

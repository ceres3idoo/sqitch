#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::revert';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    to_change
    log_only
    execute
    variables
);

is_deeply [$CLASS->options], [qw(
    target|t=s
    to-change|to|change=s
    to-target=s
    set|s=s%
    log-only
    y
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    options => {
        engine    => 'sqlite',
        plan_file => file(qw(t sql sqitch.plan))->stringify,
        top_dir   => dir(qw(t sql))->stringify,
    },
);

my $config = $sqitch->config;

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), { no_prompt => 0, prompt_accept => 1 },
    'Should have empty default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    y    => 1,
    set  => { foo => 'bar' },
}), {
    no_prompt => 1,
    prompt_accept => 1,
    variables => { foo => 'bar' },
}, 'Should have set option';

my $mock_config = Test::MockModule->new(ref $config);
my %config_vals;
$mock_config->mock(get => sub {
    my ($self, %p) = @_;
    return $config_vals{ $p{key} };
});
$mock_config->mock(get_section => sub {
    my ($self, %p) = @_;
    return $config_vals{ $p{section} } || {};
});
%config_vals = (
    'deploy.variables' => { foo => 'bar', hi => 21 },
);

is_deeply $CLASS->configure($config, {}), { no_prompt => 0, prompt_accept => 1 },
    'Should have no_prompt false, prompt_accept true';

# Make sure we can override prompting.
%config_vals = ('revert.no_prompt' => 1, 'revert.prompt_accept' => 0);
is_deeply $CLASS->configure($config, {}), { no_prompt => 1, prompt_accept => 0 },
    'Should have no_prompt true, prompt_accept false';

# But option should override.
is_deeply $CLASS->configure($config, {y => 0}), { no_prompt => 0, prompt_accept => 0 },
    'Should have no_prompt false again';

%config_vals = ('revert.no_prompt' => 0, 'revert.prompt_accept' => 1);
is_deeply $CLASS->configure($config, {}), { no_prompt => 0, prompt_accept => 1 },
    'Should have no_prompt false for false config';

is_deeply $CLASS->configure($config, {y => 1}), { no_prompt => 1, prompt_accept => 1 },
    'Should have no_prompt true with -y';

##############################################################################
# Test construction.
isa_ok my $revert = $CLASS->new(
    sqitch    => $sqitch,
    target    => 'foo',
    no_prompt => 1,
), $CLASS, 'new revert with target';
is $revert->target, 'foo', 'Should have target "foo"';
is $revert->to_change, undef, 'to_change should be undef';
isa_ok $revert = $CLASS->new(sqitch => $sqitch, no_prompt => 1), $CLASS;
is $revert->target, undef, 'Should have undef default target';
is $revert->to_change, undef, 'to_change should be undef';

##############################################################################
# Test _collect_vars.
%config_vals = ();
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $revert->_collect_vars($target) }, {}, 'Should collect no variables';

# Add core variables.
$config_vals{'core.variables'} = { prefix => 'widget', priv => 'SELECT' };
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core vars';

# Add deploy variables.
$config_vals{'deploy.variables'} = { dance => 'salsa', priv => 'UPDATE' };
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars';

# Add revert variables.
$config_vals{'revert.variables'} = { dance => 'disco', lunch => 'pizza' };
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'pizza',
}, 'Should override deploy vars with revert vars';

# Add engine variables.
$config_vals{'engine.pg.variables'} = { lunch => 'burrito', drink => 'whiskey' };
my $uri = URI::db->new('db:pg:');
$target = App::Sqitch::Target->new(sqitch => $sqitch, uri => $uri);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override revert vars with engine vars';

# Add target variables.
$config_vals{'target.foo.variables'} = { drink => 'scotch', status => 'winning' };
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override engine vars with target vars';

# Add --set variables.
$revert = $CLASS->new(
    sqitch => $sqitch,
    variables => { status => 'tired', herb => 'oregano' },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $revert->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should override target vars with --set variables';

%config_vals = ();
$revert = $CLASS->new( sqitch => $sqitch, no_prompt => 1);
##############################################################################
# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(revert => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

my $mock_cmd = Test::MockModule->new($CLASS);
my $orig_method;
$mock_cmd->mock(parse_args => sub {
    my @ret = shift->$orig_method(@_);
    $target = $ret[0][0];
    @ret;
});
$orig_method = $mock_cmd->original('parse_args');

# Pass the change.
ok $revert->execute('@alpha'), 'Execute to "@alpha"';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok !$target->engine->log_only, 'Engine should not be log_only';
is_deeply \@args, ['@alpha'],
    '"@alpha" should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass nothing.
@args = ();
ok $revert->execute, 'Execute';
is_deeply \@args, [undef],
    'undef should be passed to the engine';
is_deeply {@vars}, { },
    'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should still have no warnings';

# Pass the target.
ok $revert->execute('db:sqlite:hi'), 'Execute to target';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok !$target->engine->log_only, 'Engine should not be log_only';
is_deeply \@args, [undef],
    'undef" should be passed to the engine';
is $target->name, 'db:sqlite:hi', 'Target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass them both!
ok $revert->execute('db:sqlite:lol', 'widgets'), 'Execute with change and target';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok !$target->engine->log_only, 'Engine should not be log_only';
is_deeply \@args, ['widgets'],
    '"widgets" should be passed to the engine';
is $target->name, 'db:sqlite:lol', 'Target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# And reverse them.
ok $revert->execute('db:sqlite:lol', 'widgets'), 'Execute with target and change';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok !$target->engine->log_only, 'Engine should not be log_only';
is_deeply \@args, ['widgets'],
    '"widgets" should be passed to the engine';
is $target->name, 'db:sqlite:lol', 'Target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Now specify options.
isa_ok $revert = $CLASS->new(
    sqitch    => $sqitch,
    target    => 'db:sqlite:welp',
    to_change => 'foo',
    log_only  => 1,
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with to and variables';

@args = ();
ok $revert->execute, 'Execute again';
ok !$target->engine->no_prompt, 'Engine should not be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
is_deeply \@args, ['foo'],
    '"foo" and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is $target->name, 'db:sqlite:welp', 'Target name should be from option';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Try also passing the target and change.
ok $revert->execute('db:sqlite:lol', '@alpha'), 'Execute with options and args';
ok !$target->engine->no_prompt, 'Engine should not be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
is_deeply \@args, ['foo'],
    '"foo" and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is $target->name, 'db:sqlite:welp', 'Target name should be from option';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => 'db:sqlite:welp',
)], [__x(
        'Too many changes specified; reverting to "{change}"',
        change => 'foo',
)]], 'Should have two warnings';

# Make sure we get an exception for unknown args.
throws_ok { $revert->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'revert', 'Unknow arg ident should be "revert"';
is $@->message, __x(
    'Unknown argument "{arg}"',
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $revert->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'revert', 'Unknow args ident should be "revert"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

done_testing;

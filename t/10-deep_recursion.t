#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 18;
use Clone qw(clone);
use Config;

# Platform-adaptive depth targets.
# Windows has a 1 MB default thread stack; Cygwin typically 2 MB;
# Linux/macOS default to 8 MB but some smokers have less.
# The depths must be safe for both Clone XS recursion AND Perl's
# own recursive SvREFCNT_dec when freeing deeply nested structures.
#
# Clone.xs uses MAX_DEPTH (in rdepth units) to switch from recursive
# to iterative cloning: 2000 on Windows/Cygwin, 4000 elsewhere.
# rdepth increments twice per nesting level (once for AV, once for RV),
# so the switch happens at roughly MAX_DEPTH/2 nesting levels.
# The deep target must exceed MAX_DEPTH/2 to exercise both paths.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');

my $deep_target     = $is_limited_stack ? 4000 : 5000;

# Moderate depth used for basic tests (safe everywhere).
my $moderate_target  = 1000;

# Test 1-2: Basic deep recursion
{
    my $deep = [];
    my $curr = $deep;
    for (1..$moderate_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    my $cloned = eval { clone($deep) };
    ok(!$@, "Cloning deeply nested structure ($moderate_target levels) should not die")
        or diag("Error: $@");
    is(ref($cloned), 'ARRAY', "Cloned structure should be an array reference");
}

# Test 3-5: Very deep recursion (platform-adaptive depth)
{
    my $very_deep = [];
    my $curr = $very_deep;
    for (1..$deep_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($very_deep);
    };

    ok(!$@ && defined($cloned),
       "Should be able to clone $deep_target-deep structure without stack overflow")
        or diag("Error during clone: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed, can't verify structure", 2 if !defined $cloned;

        # Measure cloned depth
        my $measured = 0;
        my $walk = $cloned;
        while (ref($walk) eq 'ARRAY' && @$walk == 1) {
            $walk = $walk->[0];
            $measured++;
        }

        is($measured, $deep_target,
           "Cloned structure should maintain full depth ($deep_target levels)");

        # Verify clone independence: mutating the clone must not affect original
        $cloned->[0] = "mutated";
        is(ref($very_deep->[0]), 'ARRAY',
           "Mutating clone should not affect original (clone independence)");
    }
}

# Test 6-7: Deep recursion with multi-element arrays at leaves
{
    my $deep = [];
    my $curr = $deep;
    for (1..$moderate_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }
    # Put multi-element array at the leaf
    $curr->[0] = "leaf_a";
    $curr->[1] = "leaf_b";

    my $cloned = eval { clone($deep) };
    ok(!$@, "Cloning deep structure with multi-element leaf should not die")
        or diag("Error: $@");

    SKIP: {
        skip "Clone failed", 1 if !defined $cloned;

        # Walk to the leaf
        my $walk = $cloned;
        while (ref($walk) eq 'ARRAY' && @$walk == 1) {
            $walk = $walk->[0];
        }
        is_deeply($walk, ["leaf_a", "leaf_b"],
                  "Leaf multi-element array should be cloned correctly");
    }
}

# --- Hash deep-recursion tests ---
#
# Clone.xs has an iterative fallback (av_clone_iterative) for deeply nested
# arrays, but no equivalent for hashes. When rdepth exceeds MAX_DEPTH, hashes
# hit the generic fallback: SvREFCNT_inc (a shared reference, not a real clone).
# These tests document and detect that behavior.

# rdepth increments once per sv_clone call.  For a hash chain {k => {k => ...}},
# each nesting level consumes 2 rdepth ticks (one for the HV, one for the RV
# value), so the iterative-fallback boundary is at MAX_DEPTH/2 nesting levels.
my $max_depth_val    = $is_limited_stack ? 2000 : 4000;
my $hash_boundary    = int($max_depth_val / 2);  # exact boundary
my $hash_below       = int($hash_boundary * 0.6); # safely below
my $hash_above       = $hash_boundary + 200;      # safely above

# Helper: build a nested hash chain {k => {k => {k => ... => "leaf"}}}
sub build_nested_hash {
    my ($depth) = @_;
    my $root = {};
    my $curr = $root;
    for my $i (1 .. $depth - 1) {
        my $next = {};
        $curr->{k} = $next;
        $curr = $next;
    }
    $curr->{k} = "leaf";
    return $root;
}

# Helper: walk a hash chain, return (depth_reached, leaf_value)
sub walk_hash_chain {
    my ($h) = @_;
    my $depth = 0;
    while (ref($h) eq 'HASH' && exists $h->{k}) {
        $depth++;
        $h = $h->{k};
    }
    return ($depth, $h);
}

# Test 8-10: Hash chain below MAX_DEPTH boundary — full deep clone expected
{
    my $orig = build_nested_hash($hash_below);

    my $cloned = eval { clone($orig) };
    ok(!$@, "Hash clone below boundary ($hash_below levels) should not die")
        or diag("Error: $@");

    SKIP: {
        skip "Clone failed", 2 if !defined $cloned;

        my ($depth, $leaf) = walk_hash_chain($cloned);
        is($depth, $hash_below, "Cloned hash should have full depth ($hash_below)");

        # Verify independence: mutate clone, check original is untouched
        $cloned->{k} = "mutated";
        is(ref($orig->{k}), 'HASH',
           "Mutating cloned hash should not affect original (below boundary)");
    }
}

# Test 11-14: Hash chain above MAX_DEPTH boundary — detect shallow-clone fallback
{
    my $orig = build_nested_hash($hash_above);
    my ($orig_depth, $orig_leaf) = walk_hash_chain($orig);

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($orig);
    };

    ok(!$@ && defined($cloned),
       "Hash clone above boundary ($hash_above levels) should not die")
        or diag("Error: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed, can't verify structure", 3 if !defined $cloned;

        my ($clone_depth, $clone_leaf) = walk_hash_chain($cloned);

        # The clone should reach the full depth.
        # If this fails, it means the shallow fallback truncated the structure.
        is($clone_depth, $hash_above,
           "Deep hash clone should preserve full depth ($hash_above levels)")
            or diag("Clone depth: $clone_depth, expected: $hash_above — "
                   . "shallow-clone fallback may have truncated the chain");

        is($clone_leaf, "leaf",
           "Leaf value should survive deep hash clone");

        # Independence test: find a node deep enough to be past the boundary
        # and check if it's truly independent or a shared reference.
        my $walk_orig  = $orig;
        my $walk_clone = $cloned;
        my $shared_at  = -1;
        for my $i (1 .. $clone_depth) {
            last unless ref($walk_orig)  eq 'HASH' && exists $walk_orig->{k}
                     && ref($walk_clone) eq 'HASH' && exists $walk_clone->{k};
            last unless ref($walk_orig->{k})  eq 'HASH'
                     && ref($walk_clone->{k}) eq 'HASH';
            if ($walk_orig->{k} == $walk_clone->{k}) {
                $shared_at = $i;
                last;
            }
            $walk_orig  = $walk_orig->{k};
            $walk_clone = $walk_clone->{k};
        }

        # If shared_at == -1, every level is independent (ideal).
        # If shared_at > 0, the clone shares structure at that depth.
        #
        # KNOWN LIMITATION: Clone.xs has av_clone_iterative for deeply nested
        # arrays but no equivalent for hashes.  When rdepth exceeds MAX_DEPTH
        # on a hash (or a ref to a hash), the fallback is SvREFCNT_inc — a
        # shared reference, not a true clone.  This TODO documents that gap.
        TODO: {
            local $TODO = "no iterative hash clone — shares refs beyond MAX_DEPTH";
            ok($shared_at == -1,
               "Deep hash clone should be fully independent (no shared refs)");
        }
        if ($shared_at > 0) {
            diag("Shallow-clone fallback detected at depth $shared_at of $hash_above");
        }
    }
}

# Test 15-16: Mixed hash-in-array nesting beyond MAX_DEPTH
# Arrays have iterative fallback but hashes inside them do not.
{
    my $depth = $hash_above;
    my $root = [];
    my $curr = $root;
    for my $i (1 .. $depth) {
        my $h = { data => $i };
        $curr->[0] = $h;
        if ($i < $depth) {
            my $next = [];
            $h->{next} = $next;
            $curr = $next;
        }
    }

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($root);
    };

    ok(!$@ && defined($cloned),
       "Mixed array/hash deep nesting ($depth levels) should not die")
        or diag("Error: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed", 1 if !defined $cloned;

        # Check first level is independent
        isnt($root->[0], $cloned->[0],
             "Top-level hash in mixed structure should be a distinct clone");
    }
}

# Test 17-18: Hash with multiple keys at each level beyond MAX_DEPTH
# Wider hashes may behave differently than single-key chains.
{
    my $depth = int($hash_boundary * 1.2);
    my $root = {};
    my $curr = $root;
    for my $i (1 .. $depth - 1) {
        my $next = {};
        $curr->{child} = $next;
        $curr->{val}   = "v$i";
        $curr->{idx}   = $i;
        $curr = $next;
    }
    $curr->{child} = "end";
    $curr->{val}   = "final";

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($root);
    };

    ok(!$@ && defined($cloned),
       "Multi-key hash chain ($depth levels) should not die")
        or diag("Error: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed", 1 if !defined $cloned;

        is($cloned->{val}, "v1",
           "Top-level value in multi-key hash should be cloned correctly");
    }
}

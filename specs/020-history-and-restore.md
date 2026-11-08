# 020-history-and-restore

## Summary

History views and restore operations over the changelog and Mutation journal (002): one row's Changes across time, what a write overwrote, every rejected Mutation with its payload and problem, and RPCs that restore an overwritten value or re-apply a rejected Mutation as a new write. Restores never edit the log. They are ordinary writes recorded by `Changelog.write`, and they require `netaid:Restore*`, which only admins hold (001).

## Motivation

## Explanation

## Drawbacks

## Considered Alternatives

## Prior Art

## Security and Privacy Considerations

## Mission Scope

### Out of scope

### Expected Outcomes

## Implementation Plan

## Current Status

Skeleton: summary and headings only. Interview not started.

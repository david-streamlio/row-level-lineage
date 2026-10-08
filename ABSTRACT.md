# Accepted talk abstract

Recorded verbatim 2026-10-06. The abstract is accepted and can't change; see
`TALK-OUTLINE.md` for how each point is covered.

## Iceberg V3 Meets the Lakehouse: Row-Level Lineage and Schema Evolution for Streaming Data

Apache Iceberg V3 changes what's possible for Lakehouse governance -- but most discussions focus on batch scenarios. This session explores what V3 means for organizations streaming real-time data into their Lakehouse, where governance and lineage must evolve beyond batch assumptions.

We'll show how Lakehouse-native streaming integrates with Iceberg V3 and REST catalogs to bring fine-grained governance to continuously ingested data. The centerpiece is row-level lineage: understanding not just which table data came from, but which specific records and transformations produced it, even as data arrives continuously. We'll also cover schema evolution patterns for streaming sources -- where schemas change without warning and pipelines can't just stop and restart.

The talk introduces a Bring Your Own Lineage (BYOL) model: how to integrate your preferred lineage systems alongside your catalog without disrupting streaming pipelines. This session shows how Iceberg V3, catalog governance, and Lakehouse-native streaming deliver trustworthy, auditable data from the moment it's ingested.

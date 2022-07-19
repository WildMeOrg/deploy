# Load Existing Data


## Load existing data from a WildBook instance

The steps listed here are used to transition a WildBook instance to Codex.

Jon is the goto person to acquiring the sql dump file. As of the writing of this portion of the documentation, the processed used to produce those results is unknown to me.

### Preparation

1. You will need (rsync) access to the asset files
1. You need to obtain or build a migrations tarball containing the edm and houston database dump files and the assets tsv data.

### Importing the data

    ./import-data.sh


## Replicate an existing Codex instance

This set of instructions should be used to replicate an existing instance of Codex. For example, you may want to replicate a production instance for staging new experimental changes.

Note, these instructions are currently oriented towards replicating the data from an instance of codex that is deployed on a VM using the docker-compose scenario.

### Preparation

1. You will need an empty deployment of Codex
1. You will need access to the database backup files
1. You will need (rsync) access to the asset files

### Importing the data

    ./replicate-from-backup.sh

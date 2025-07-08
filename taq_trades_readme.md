# TAQ Data Implementation in TimescaleDB

This repository contains python scripts and SQL commands for efficiently loading, storing, and querying Trade and Quote (TAQ) data using [TimescaleDB](https://github.com/timescale/timescaledb). The implementation is optimized for high-performance time-series analysis of financial market data. Currently it is only for loading the master trades file, but I'm looking to expand to importing NBBO (near bids best offer) data as well. 

Example TAQ data files can be [downloaded from the NYSE site](https://ftp.nyse.com/Historical%20Data%20Samples/DAILY%20TAQ/)

## Technical Overview

### Schema Design

The implementation uses a schema that preserves the structure of TAQ data while optimizing for query performance:

```sql
CREATE TABLE taq_trades (
    time_stamp BIGINT NOT NULL, -- Store raw nanosecond timestamp
    exchange CHAR(1),
    symbol VARCHAR(17),
    sale_condition VARCHAR(4),
    trade_volume BIGINT,
    trade_price NUMERIC(21,8),
    trade_stop_stock_indicator CHAR(1),
    trade_correction_indicator CHAR(2),
    sequence_number BIGINT,
    trade_id VARCHAR(20),
    source_of_trade CHAR(1),
    trade_reporting_facility CHAR(1),
    participant_timestamp BIGINT,
    trf_timestamp BIGINT,
    trade_through_exempt_indicator CHAR(1)
);
```

Design notes:
- `time_stamp` stored as BIGINT to preserve nanosecond precision
- Appropriate data types chosen to balance storage efficiency and query performance
- VARCHAR fields sized appropriately for TAQ data standards

### TimescaleDB Hypertable Configuration

Converting the standard table to a TimescaleDB hypertable enables automatic time-based partitioning:

```sql
SELECT create_hypertable('taq_trades', 'time_stamp',
    chunk_time_interval => 3600000000000);
```

This creates a hypertable with:
- Time-based chunks of 1 hour (3,600,000,000,000 nanoseconds)
- Automatic partitioning based on the `time_stamp` column

### Index Optimization

Strategic indexes support common query patterns:

```sql
-- Create index for symbol-based queries
CREATE INDEX ON taq_trades (symbol, time_stamp);

-- Create index for exchange-based queries
CREATE INDEX ON taq_trades (exchange, time_stamp);
```

These compound indexes optimize for:
- Queries filtering by symbol and time range
- Queries filtering by exchange and time range
- Time-ordered access within symbol or exchange groups

### Compression Strategy

TimescaleDB's native compression capabilities are configured for optimal space efficiency:

```sql
-- Enable compression on the table
ALTER TABLE taq_trades SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'symbol, exchange',
    timescaledb.compress_orderby = 'time_stamp'
);

-- Create a compression policy (compress chunks older than 1 day)
SELECT add_compression_policy('taq_trades', BIGINT '86400000000000'); -- 1 day in nanoseconds
```

The compression configuration:
- Segments data by symbol and exchange to maintain query efficiency
- Orders compressed data by timestamp to preserve time-series characteristics
- Automatically compresses data older than 1 day

### Data Ingestion with Python Parallel Processing

An alternative approach to data ingestion uses a Python script that splits the TAQ file into chunks and processes them in parallel using PostgreSQL's `\copy` command. While this method provides more control over the import process, it is significantly slower than the timescaledb-parallel-copy tool.

The Python script (`taq_import.py`) performs the following operations:
1. Preprocesses the TAQ data file to remove headers and footers
2. Splits the file into configurable chunks (default: 8)
3. Imports each chunk in parallel using multiprocessing
4. Provides detailed progress reporting and error handling

Usage:
```bash
# Basic usage with required file parameter
./taq_import.py -f /path/to/EQY_US_ALL_TRADE_20250102

# Specify custom number of chunks
./taq_import.py -f /path/to/EQY_US_ALL_TRADE_20250102 -c 16

# View help
./taq_import.py -h
```

**Performance Note**: This Python-based approach took over 20 minutes to import a full day's TAQ data file, compared to the much faster timescaledb-parallel-copy method described below. The Python script is useful for environments where timescaledb-parallel-copy is not available or when additional preprocessing logic is needed.

### Data Ingestion with Parallel Copy

The TAQ trades file will include a header and the last row will not contain data, so first we will need to trim these two lines out of the file we can use `sed`:

```bash
sed '1d;$d' EQY_US_ALL_TRADE_20250102 > CLEAN_EQY_US_ALL_TRADE_20250102
```

The fastest method of copying data into TimescaleDB is to utilize [timescaledb-parallel-copy](https://github.com/timescale/timescaledb-parallel-copy)

```bash
timescaledb-parallel-copy \
    --connection "host=localhost user=postgres sslmode=disable dbname=postgres"\
    --table taq_trades \
    --file "CLEAN_EQY_US_ALL_TRADE_20250102"\
    --workers 16 \
    --batch-size 50000 \
    --reporting-period 15s \
    --split "|" \
    --copy-options "CSV"
```


The alternative , but slower is to:
```sql
\copy taq_trades FROM PROGRAM 'sed 1d /home/james/EQY_US_ALL_TRADE_20250102 | head -n -1' WITH (FORMAT CSV, DELIMITER '|');
```

Here we use:
- `sed` to remove header row
- `head` to remove potential trailing line
- PostgreSQL's COPY mechanism
- Handles pipe-delimited TAQ data files

## Performance Considerations

### Query Patterns

This is optimized for:
- Time-range queries for specific symbols
- Time-range queries for specific exchanges
- Aggregation queries over time windows
- Point-in-time market state reconstruction

## Usage Examples

### Basic Queries

Retrieve all trades for a specific symbol on a given day:

```sql
SELECT * FROM taq_trades 
WHERE symbol = 'AAPL' 
AND time_stamp BETWEEN 1609459200000000000 AND 1609545599999999999 
ORDER BY time_stamp;
```

Calculate VWAP (Volume-Weighted Average Price) for a symbol over time buckets:

```sql
SELECT 
    time_bucket(1000000000000, time_stamp) AS minute_bucket,
    symbol,
    SUM(trade_volume * trade_price) / SUM(trade_volume) AS vwap
FROM taq_trades
WHERE symbol = 'MSFT'
AND time_stamp BETWEEN 1609459200000000000 AND 1609545599999999999
GROUP BY minute_bucket, symbol
ORDER BY minute_bucket;
```

### Advanced Query

Join with quotes table (if available) to analyze spreads:

```sql
SELECT 
    t.time_stamp,
    t.symbol,
    t.trade_price,
    q.bid_price,
    q.ask_price,
    q.ask_price - q.bid_price AS spread
FROM taq_trades t
JOIN taq_quotes q ON 
    t.symbol = q.symbol AND 
    t.time_stamp BETWEEN q.time_stamp AND LEAD(q.time_stamp) OVER (PARTITION BY q.symbol ORDER BY q.time_stamp)
WHERE t.symbol = 'AAPL'
AND t.time_stamp BETWEEN 1609459200000000000 AND 1609459300000000000
ORDER BY t.time_stamp;
```

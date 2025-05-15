# TAQ Data Implementation in TimescaleDB

This repository contains SQL commands for efficiently loading, storing, and querying Trade and Quote (TAQ) data using TimescaleDB. The implementation is optimized for high-performance time-series analysis of financial market data.

## Technical Overview

### Schema Design

The implementation uses a carefully designed schema that preserves the structure of TAQ data while optimizing for query performance:

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

### Data Ingestion

Efficient data loading using PostgreSQL's COPY command with Unix tools:

```sql
\copy taq_trades FROM PROGRAM 'sed 1d /home/james/EQY_US_ALL_TRADE_20250102 | head -n -1' WITH (FORMAT CSV, DELIMITER '|');
```

Here we use:
- `sed` to remove header row
- `head` to remove potential trailing line
- Leverages PostgreSQL's fast COPY mechanism
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


CREATE TABLE taq_trades (
    time_stamp BIGINT NOT NULL,  -- Store raw nanosecond timestamp
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


-- Convert to hypertable with a chunk interval of 1 hour in nanoseconds
-- 3,600,000,000,000 nanoseconds = 1 hour
SELECT create_hypertable('taq_trades', 'time_stamp', 
                         chunk_time_interval => 3600000000000);

-- Create index for symbol-based queries
CREATE INDEX ON taq_trades (symbol, time_stamp);

-- Create index for exchange-based queries
CREATE INDEX ON taq_trades (exchange, time_stamp);


-- Enable compression on the table
ALTER TABLE taq_trades SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'symbol, exchange',
    timescaledb.compress_orderby = 'time_stamp'
);

-- Create a compression policy (compress chunks older than 1 day)
SELECT add_compression_policy('taq_trades', BIGINT '86400000000000');  -- 1 day in nanoseconds
                         chunk_time_interval => 3600000000000);


-- Loading the ALL TRADE example file located at https://ftp.nyse.com/Historical%20Data%20Samples/DAILY%20TAQ/EQY_US_ALL_TRADE_20250102.gz
-- The last row in the TAQ file does not contain valid data, so we skip it. 
-- Run via psql

\copy taq_trades FROM PROGRAM 'sed 1d ./EQY_US_ALL_TRADE_20250102 | head -n -1' WITH (FORMAT CSV, DELIMITER '|');

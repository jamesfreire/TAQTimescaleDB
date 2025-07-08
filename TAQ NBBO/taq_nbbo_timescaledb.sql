-- =============================================================================
-- TAQ NBBO TimescaleDB Implementation
-- High-Performance Financial Market Data Pipeline
-- Processing 440M+ daily NBBO records with nanosecond precision
-- james.freire@gmail.com
-- =============================================================================

-- =============================================================================
-- 1. TABLE CREATION
-- =============================================================================

CREATE TABLE taq_nbbo (
    -- Import and data tracking
    import_date DATE NOT NULL DEFAULT CURRENT_DATE,
    data_date DATE NOT NULL,  -- Date of the actual TAQ data (from filename)
    
    -- Core timestamp and identification  
    time BIGINT NOT NULL,     -- Nanoseconds since midnight for data_date
    exchange CHAR(1) NOT NULL,
    symbol VARCHAR(17) NOT NULL,
    
    -- Quote data (current exchange quote that triggered NBBO change)
    bid_price DECIMAL(12,6),
    bid_size INTEGER,
    offer_price DECIMAL(12,6),
    offer_size INTEGER,
    quote_condition CHAR(1),
    sequence_number BIGINT NOT NULL,
    
    -- NBBO indicators and metadata
    national_bbo_indicator CHAR(1),
    finra_bbo_indicator CHAR(1),
    finra_adf_mpid_indicator SMALLINT,
    quote_cancel_correction CHAR(1),
    source_of_quote CHAR(1) NOT NULL,
    
    -- Best Bid information (consolidated)
    best_bid_quote_condition CHAR(1),
    best_bid_exchange CHAR(1),
    best_bid_price DECIMAL(12,6),
    best_bid_size INTEGER,
    best_bid_finra_market_maker_id CHAR(4),
    
    -- Best Offer information (consolidated)
    best_offer_quote_condition CHAR(1),
    best_offer_exchange CHAR(1),
    best_offer_price DECIMAL(12,6),
    best_offer_size INTEGER,
    best_offer_finra_market_maker_id CHAR(4),
    
    -- LULD and regulatory indicators
    luld_bbo_indicator CHAR(1),
    nbbo_luld_indicator CHAR(1),
    sip_generated_message_identifier CHAR(1),
    
    -- Timestamps (nanoseconds since midnight)
    participant_timestamp BIGINT,
    finra_adf_timestamp BIGINT,
    
    -- Status indicators
    security_status_indicator CHAR(2),
    
    -- Import tracking
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
    	)
    WITH (
  tsdb.hypertable,
  tsdb.partition_column = 'data_date',
  tsdb.chunk_interval = '1 day',
  tsdb.segmentby = 'symbol, exchange',
  tsdb.orderby = 'data_date, time DESC',
  tsdb.create_default_indexes = false
);


-- =============================================================================
-- 2. INDEXES FOR OPTIMAL QUERY PERFORMANCE
-- =============================================================================

-- Primary index for time-series queries
CREATE INDEX idx_taq_nbbo_data_date_time 
ON taq_nbbo (data_date, time);

-- Symbol-based queries (most common)
CREATE INDEX idx_taq_nbbo_symbol_data_date 
ON taq_nbbo (symbol, data_date, time);

-- Exchange-based analysis
CREATE INDEX idx_taq_nbbo_exchange_data_date 
ON taq_nbbo (exchange, data_date, time);

-- Sequence number for data integrity checks
CREATE INDEX idx_taq_nbbo_sequence 
ON taq_nbbo (data_date, sequence_number);

-- =============================================================================
-- 3. COMPRESSION CONFIGURATION
-- =============================================================================

-- Configure compression for optimal storage and query performance
ALTER TABLE taq_nbbo SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'time DESC, sequence_number DESC',
    timescaledb.compress_segmentby = 'data_date, symbol, exchange'
);

-- Compression policy - compress data older than 1 day
SELECT add_compression_policy('taq_nbbo', INTERVAL '1 day');

-- =============================================================================
-- 4. UTILITY FUNCTIONS FOR TIME CONVERSION
-- =============================================================================

-- Convert TAQ timestamp (HHMMSSxxxxxxxxx format) to market time

CREATE OR REPLACE FUNCTION ns_to_market_time(
    data_date DATE,
    taq_timestamp BIGINT,
    timezone_name TEXT DEFAULT 'America/New_York'
) RETURNS TIMESTAMPTZ AS $$
DECLARE
    time_str TEXT;
    hours INTEGER;
    minutes INTEGER;
    seconds INTEGER;
    nanoseconds BIGINT;
    base_timestamp TIMESTAMPTZ;
BEGIN
    -- Handle NULL or negative values
    IF taq_timestamp IS NULL OR taq_timestamp < 0 THEN
        RETURN NULL;
    END IF;

    -- Convert BIGINT to 15-character string with leading zeros
    time_str := LPAD(taq_timestamp::TEXT, 15, '0');

    -- Validate format (should be exactly 15 characters)
    IF LENGTH(time_str) != 15 THEN
        RAISE WARNING 'Invalid timestamp length: % (length: %)', time_str, LENGTH(time_str);
        RETURN NULL;
    END IF;

    -- Parse HHMMSSxxxxxxxxx format
    BEGIN
        hours := SUBSTRING(time_str, 1, 2)::INTEGER;
        minutes := SUBSTRING(time_str, 3, 2)::INTEGER;
        seconds := SUBSTRING(time_str, 5, 2)::INTEGER;
        nanoseconds := SUBSTRING(time_str, 7, 9)::BIGINT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to parse timestamp components from: %', time_str;
        RETURN NULL;
    END;

    -- Validate time components
    IF hours > 23 OR minutes > 59 OR seconds > 59 THEN
        RAISE WARNING 'Invalid time components: %:%:% from %', hours, minutes, seconds, time_str;
        RETURN NULL;
    END IF;

    -- Create base timestamp in specified timezone
    BEGIN
        base_timestamp := (data_date + 
            (hours || ' hours')::INTERVAL + 
            (minutes || ' minutes')::INTERVAL + 
            (seconds || ' seconds')::INTERVAL
        ) AT TIME ZONE timezone_name;
        
        -- Add nanoseconds (converted to microseconds for PostgreSQL)
        RETURN base_timestamp + (nanoseconds / 1000.0 || ' microseconds')::INTERVAL;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to create timestamp for date: %, time: %:%:%', data_date, hours, minutes, seconds;
        RETURN NULL;
    END;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Unexpected error in ns_to_market_time: %', SQLERRM;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;


-- =============================================================================
-- 5. DATA VALIDATION FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION is_regular_trading_hours(
    data_date DATE,
    taq_timestamp BIGINT
) RETURNS BOOLEAN AS $$
BEGIN
    -- 9:30 AM = 093000000000000, 4:00 PM = 160000000000000
    RETURN taq_timestamp >= 093000000000000 AND taq_timestamp <= 160000000000000;
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;


-- Validate imported data for a specific date
CREATE OR REPLACE FUNCTION validate_nbbo_data(target_date DATE)
RETURNS TABLE (
    validation_check TEXT,
    status TEXT,
    count_or_value BIGINT,
    details TEXT
) AS $$
BEGIN
    -- Check record count
    RETURN QUERY
    SELECT 
        'Total Records'::TEXT,
        'INFO'::TEXT,
        COUNT(*)::BIGINT,
        'Total NBBO records for ' || target_date::TEXT
    FROM taq_nbbo WHERE data_date = target_date;
    
    -- Check for NULL required fields
    RETURN QUERY
    SELECT 
        'NULL Required Fields'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
        COUNT(*)::BIGINT,
        'Records with NULL in required fields (time, symbol, exchange, sequence_number)'
    FROM taq_nbbo 
    WHERE data_date = target_date 
      AND (time IS NULL OR symbol IS NULL OR exchange IS NULL OR sequence_number IS NULL);
    
    -- Check time range validity (TAQ HHMMSSxxxxxxxxx format)
    RETURN QUERY
    SELECT 
        'Invalid Time Format'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
        COUNT(*)::BIGINT,
        'Records with time outside valid TAQ format (HHMMSSxxxxxxxxx)'
    FROM taq_nbbo 
    WHERE data_date = target_date 
      AND (time < 0 OR time > 999999999999999 OR LENGTH(time::TEXT) > 15);
    
    -- Check for duplicate sequence numbers
    RETURN QUERY
    WITH duplicates AS (
        SELECT sequence_number, COUNT(*) as dup_count
        FROM taq_nbbo 
        WHERE data_date = target_date
        GROUP BY sequence_number
        HAVING COUNT(*) > 1
    )
    SELECT 
        'Duplicate Sequence Numbers'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END::TEXT,
        COUNT(*)::BIGINT,
        'Sequence numbers appearing multiple times'
    FROM duplicates;
    
    -- Check symbol distribution
    RETURN QUERY
    SELECT 
        'Unique Symbols'::TEXT,
        'INFO'::TEXT,
        COUNT(DISTINCT symbol)::BIGINT,
        'Number of unique symbols in dataset'
    FROM taq_nbbo WHERE data_date = target_date;
    
    -- Check trading hours coverage
    RETURN QUERY
    SELECT 
        'Regular Trading Hours Records'::TEXT,
        'INFO'::TEXT,
        COUNT(*)::BIGINT,
        'Records during regular trading hours (9:30 AM - 4:00 PM ET)'
    FROM taq_nbbo 
    WHERE data_date = target_date 
      AND is_regular_trading_hours(data_date, time);
END;
$$ LANGUAGE plpgsql;


-- Materialized view for daily summary statistics (refresh after daily load)
CREATE MATERIALIZED VIEW daily_nbbo_summary AS
SELECT 
    data_date,
    symbol,
    COUNT(*) as total_quotes,
    COUNT(*) FILTER (WHERE is_regular_trading_hours(data_date, time)) as trading_hours_quotes,
    AVG(best_offer_price - best_bid_price) as avg_spread,
    MIN(best_offer_price - best_bid_price) as min_spread,
    MAX(best_offer_price - best_bid_price) as max_spread,
    AVG(best_bid_price) as avg_bid,
    AVG(best_offer_price) as avg_offer,
    MIN(time) as first_quote_ns,
    MAX(time) as last_quote_ns,
    COUNT(DISTINCT exchange) as exchange_count,
    COUNT(DISTINCT best_bid_exchange) as bid_exchange_count,
    COUNT(DISTINCT best_offer_exchange) as offer_exchange_count
FROM taq_nbbo
WHERE best_bid_price > 0 AND best_offer_price > 0
GROUP BY data_date, symbol;

-- Index on materialized view
CREATE INDEX idx_daily_nbbo_summary_date_symbol ON daily_nbbo_summary (data_date, symbol);




-- Calculate daily NBBO statistics
CREATE OR REPLACE FUNCTION daily_nbbo_stats(target_date DATE)
RETURNS TABLE (
    symbol VARCHAR(17),
    quote_count BIGINT,
    avg_spread DECIMAL(12,6),
    min_spread DECIMAL(12,6),
    max_spread DECIMAL(12,6),
    avg_bid_price DECIMAL(12,6),
    avg_offer_price DECIMAL(12,6),
    trading_hours_quotes BIGINT,
    first_quote_time_ns BIGINT,
    last_quote_time_ns BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        n.symbol,
        COUNT(*) AS quote_count,
        AVG(n.best_offer_price - n.best_bid_price) AS avg_spread,
        MIN(n.best_offer_price - n.best_bid_price) AS min_spread,
        MAX(n.best_offer_price - n.best_bid_price) AS max_spread,
        AVG(n.best_bid_price) AS avg_bid_price,
        AVG(n.best_offer_price) AS avg_offer_price,
        COUNT(*) FILTER (WHERE is_regular_trading_hours(n.data_date, n.time)) AS trading_hours_quotes,
        MIN(n.time) AS first_quote_time_ns,
        MAX(n.time) AS last_quote_time_ns
    FROM taq_nbbo n
    WHERE n.data_date = target_date
      AND n.best_bid_price > 0 
      AND n.best_offer_price > 0
    GROUP BY n.symbol
    ORDER BY n.symbol;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- Market Analysis Examples
-- =============================================================================


-- Daily Spread Statistics by Symbol:

SELECT * FROM daily_nbbo_stats('2025-01-02') 
WHERE symbol IN ('AAPL', 'MSFT')
ORDER BY avg_spread;



-- Get NBBO snapshot at specific time using TAQ timestamp format
2:30 PM = 143000000000000 (HHMMSSxxxxxxxxx)
WITH latest_quotes AS (
    SELECT DISTINCT ON (symbol)
        symbol,
        best_bid_price,
        best_bid_size,
        best_bid_exchange,
        best_offer_price,
        best_offer_size,
        best_offer_exchange,
        best_offer_price - best_bid_price as spread,
        time,
        ns_to_market_time(data_date, time) as market_time
    FROM taq_nbbo
    WHERE data_date = '2025-01-02'
      AND time >= 142900000000000  -- 2:29 PM (1 minute before)
      AND time <= 143100000000000  -- 2:31 PM (1 minute after)
      AND best_bid_price > 0 
      AND best_offer_price > 0
    ORDER BY symbol, time DESC, sequence_number DESC
)
SELECT * FROM latest_quotes 
WHERE spread IS NOT NULL
ORDER BY symbol;
Market open snapshot (9:30 AM): 0.21 seconds

SELECT 
    symbol,
    best_bid_price,
    best_offer_price,
    best_offer_price - best_bid_price as spread,
    best_bid_exchange,
    best_offer_exchange
FROM taq_nbbo
WHERE data_date = '2025-01-02'
  AND time >= 093000000000000  -- Exactly 9:30:00 AM
  AND time <= 093100000000000  -- Within first minute
  AND best_bid_price > 0 
  AND best_offer_price > 0
ORDER BY symbol, time DESC
LIMIT 100;


-- Cross-sectional analysis: widest spreads at market close: 12 seconds

WITH close_quotes AS (
    SELECT DISTINCT ON (symbol)
        symbol,
        best_bid_price,
        best_offer_price,
        best_offer_price - best_bid_price as spread,
        time
    FROM taq_nbbo
    WHERE data_date = '2025-01-02'
      AND time >= 155900000000000  -- 3:59 PM
      AND time <= 160000000000000  -- 4:00 PM
      AND best_bid_price > 0 
      AND best_offer_price > 0
    ORDER BY symbol, time DESC
)
SELECT symbol, best_bid_price, best_offer_price, spread
FROM close_quotes
ORDER BY spread DESC
LIMIT 20;


-- AAPL quotes during first hour of trading
SELECT 
    ns_to_market_time(data_date, time) as market_time,
    best_bid_price, 
    best_offer_price,
    best_offer_price - best_bid_price as spread
FROM taq_nbbo 
WHERE symbol = 'AAPL' 
  AND data_date = '2025-01-02'
  AND time >= 093000000000000  -- 9:30 AM
  AND time <= 103000000000000  -- 10:30 AM
ORDER BY time;



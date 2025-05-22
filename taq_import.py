#!/usr/bin/env python3
import os
import subprocess
import time
from datetime import datetime
from multiprocessing import Pool
import sys
import argparse

def import_chunk(args):
    chunk_index, chunk_file, total_chunks = args
    start_time = time.time()
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Starting import of chunk {chunk_index+1}/{total_chunks}: {os.path.basename(chunk_file)}")
    sys.stdout.flush()
    
    cmd = f"psql -c \"\\copy taq_trades FROM '{chunk_file}' WITH (FORMAT CSV, DELIMITER '|');\" postgres"
    process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = process.communicate()
    
    elapsed_time = time.time() - start_time
    result = process.returncode
    
    if result == 0:
        status = "SUCCESS"
    else:
        status = "FAILED"
        print(f"Error output: {stderr.decode()}")
    
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {status}: Chunk {chunk_index+1}/{total_chunks} completed in {elapsed_time:.2f} seconds")
    sys.stdout.flush()
    
    return {
        "chunk": chunk_index + 1,
        "file": chunk_file,
        "status": status,
        "time": elapsed_time,
        "result": result
    }

def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Import TAQ trade data into PostgreSQL database')
    parser.add_argument('-f', '--file', required=True, 
                       help='Path to the TAQ trade data file to import')
    parser.add_argument('-c', '--chunks', type=int, default=8,
                       help='Number of chunks to split the file into (default: 8)')
    
    args = parser.parse_args()
    
    # Validate that the input file exists
    if not os.path.exists(args.file):
        print(f"Error: File '{args.file}' does not exist.")
        sys.exit(1)
    
    overall_start_time = time.time()
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Starting TAQ trade data import")
    print(f"Input file: {args.file}")
    print(f"Number of chunks: {args.chunks}")
    
    # Number of chunks to create
    num_chunks = args.chunks
    
    # Preprocess to remove header and footer
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Preprocessing file (removing header and footer)")
    os.system(f"sed '1d;$d' '{args.file}' > /tmp/taq_clean")
    
    # Count lines to split evenly
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Counting lines to split file evenly")
    total_lines = int(subprocess.check_output("wc -l < /tmp/taq_clean", shell=True).decode().strip())
    chunk_size = total_lines // num_chunks
    print(f"Total lines: {total_lines}, splitting into {num_chunks} chunks of ~{chunk_size} lines each")
    
    # Create chunk files
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Creating {num_chunks} chunk files")
    chunk_files = []
    for i in range(num_chunks):
        start = i * chunk_size + 1
        end = (i + 1) * chunk_size if i < num_chunks - 1 else total_lines
        chunk_file = f"/tmp/taq_chunk_{i}.csv"
        print(f"Creating chunk {i+1}/{num_chunks}: lines {start}-{end} -> {chunk_file}")
        os.system(f"sed -n '{start},{end}p' /tmp/taq_clean > {chunk_file}")
        chunk_files.append(chunk_file)
    
    # Import in parallel
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Starting parallel import of {len(chunk_files)} chunks")
    chunk_args = [(i, f, len(chunk_files)) for i, f in enumerate(chunk_files)]
    
    with Pool(num_chunks) as p:
        results = p.map(import_chunk, chunk_args)
    
    # Report final results
    overall_elapsed_time = time.time() - overall_start_time
    print("\n" + "="*50)
    print(f"IMPORT JOB COMPLETED in {overall_elapsed_time:.2f} seconds")
    print("="*50)
    
    # Summary of chunks
    success_count = sum(1 for r in results if r["status"] == "SUCCESS")
    success_time = sum(r["time"] for r in results if r["status"] == "SUCCESS")
    
    print(f"Total chunks: {len(results)}")
    print(f"Successful chunks: {success_count}")
    print(f"Failed chunks: {len(results) - success_count}")
    
    if success_count > 0:
        print(f"Average time per successful chunk: {success_time/success_count:.2f} seconds")
    
    # Detailed results
    print("\nDETAILED RESULTS:")
    sorted_results = sorted(results, key=lambda x: x["chunk"])
    for r in sorted_results:
        print(f"Chunk {r['chunk']}: {r['status']} in {r['time']:.2f} seconds")
    
    # Clean up
    if all(r["status"] == "SUCCESS" for r in results):
        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Cleaning up temporary files")
        for chunk_file in chunk_files:
            os.remove(chunk_file)
        os.remove("/tmp/taq_clean")
    else:
        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Some imports failed. Temporary files kept for debugging.")

if __name__ == "__main__":
    main()
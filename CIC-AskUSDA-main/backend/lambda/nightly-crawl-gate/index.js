const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');
const { S3Client, ListObjectsV2Command } = require('@aws-sdk/client-s3');

const s3Client = new S3Client({});
const lambdaClient = new LambdaClient({});

const CRAWLER_BUCKET = process.env.CRAWLER_BUCKET;
const CRAWL_PREFIX = process.env.CRAWL_PREFIX || 'jobs/';
const KBSYNC_FUNCTION_NAME = process.env.KBSYNC_FUNCTION_NAME;

async function hasCrawledData() {
  const response = await s3Client.send(new ListObjectsV2Command({
    Bucket: CRAWLER_BUCKET,
    Prefix: CRAWL_PREFIX,
    MaxKeys: 1,
  }));

  return (response.KeyCount || 0) > 0 || (response.CommonPrefixes || []).length > 0 || (response.Contents || []).length > 0;
}

exports.handler = async () => {
  // Modification of the existing crawler-to-sync flow:
  // This gate only forwards the nightly crawl when prior crawl output exists.
  if (!CRAWLER_BUCKET || !KBSYNC_FUNCTION_NAME) {
    throw new Error('CRAWLER_BUCKET and KBSYNC_FUNCTION_NAME are required');
  }

  const crawledDataExists = await hasCrawledData();
  if (!crawledDataExists) {
    console.log(`[NIGHTLY-DELTA] No crawled data found in ${CRAWLER_BUCKET}/${CRAWL_PREFIX}; skipping nightly delta crawl.`);
    return {
      status: 'skipped',
      reason: 'no crawled data found',
    };
  }

  console.log(`[NIGHTLY-DELTA] Crawled data detected. Invoking ${KBSYNC_FUNCTION_NAME} for delta ingestion.`);
  const response = await lambdaClient.send(new InvokeCommand({
    FunctionName: KBSYNC_FUNCTION_NAME,
    InvocationType: 'Event',
    Payload: Buffer.from(JSON.stringify({ action: 'ingest' })),
  }));

  return {
    status: 'invoked',
    statusCode: response.StatusCode,
  };
};
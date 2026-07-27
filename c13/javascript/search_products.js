import fs from "node:fs";
import { pathToFileURL } from "node:url";

import { Client } from "@elastic/elasticsearch";

export const INDEX_NAME = "application-client-products-read";
export const MAX_PAGE_SIZE = 100;
export const MAX_429_RETRIES = 3;
export const INITIAL_RETRY_DELAY_MS = 100;

function requireEnvironmentVariable(name, environment) {
  const value = environment[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Environment variable ${name} is required`);
  }
  return value;
}

export function createClient(environment = process.env) {
  const url = requireEnvironmentVariable("ES_URL", environment);
  const caPath = requireEnvironmentVariable("ES_CA", environment);
  const apiKey = requireEnvironmentVariable("ES_API_KEY", environment);

  return new Client({
    node: url,
    auth: { apiKey },
    tls: { ca: fs.readFileSync(caPath) },
    requestTimeout: 2000,
    maxRetries: 3,
  });
}

export function buildProductSearch({ keyword, category, pageSize = 20 }) {
  if (typeof keyword !== "string" || keyword.trim().length === 0) {
    throw new TypeError("keyword must be a non-empty string");
  }
  if (
    category !== undefined &&
    category !== null &&
    (typeof category !== "string" || category.trim().length === 0)
  ) {
    throw new TypeError("category must be a non-empty string when provided");
  }
  if (!Number.isFinite(pageSize)) {
    throw new TypeError("pageSize must be a finite number");
  }

  const size = Math.min(Math.max(Math.trunc(pageSize), 1), MAX_PAGE_SIZE);
  const filters = [{ term: { available: true } }];
  if (category !== undefined && category !== null) {
    filters.push({ term: { category } });
  }

  return {
    index: INDEX_NAME,
    size,
    _source: ["product_id", "name", "price", "stock"],
    query: {
      bool: {
        must: [
          {
            multi_match: {
              query: keyword,
              fields: ["name^3", "description"],
            },
          },
        ],
        filter: filters,
      },
    },
  };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function searchProducts(
  client,
  options,
  {
    max429Retries = MAX_429_RETRIES,
    initialRetryDelayMs = INITIAL_RETRY_DELAY_MS,
    sleep = delay,
  } = {},
) {
  const request = buildProductSearch(options);

  for (let attempt = 0; ; attempt += 1) {
    try {
      return await client.search(request, { retryOnTimeout: true });
    } catch (error) {
      if (error?.statusCode !== 429 || attempt >= max429Retries) {
        throw error;
      }
      await sleep(initialRetryDelayMs * 2 ** attempt);
    }
  }
}

export async function main() {
  const client = createClient();
  try {
    const result = await searchProducts(client, {
      keyword: "无线键盘",
      category: "keyboard",
    });
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await client.close();
  }
}

const isMain =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}

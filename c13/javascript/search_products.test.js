import assert from "node:assert/strict";
import test from "node:test";

import {
  INITIAL_RETRY_DELAY_MS,
  INDEX_NAME,
  MAX_429_RETRIES,
  MAX_PAGE_SIZE,
  buildProductSearch,
  searchProducts,
} from "./search_products.js";

test("buildProductSearch creates the constrained product query", () => {
  const request = buildProductSearch({
    keyword: "无线键盘",
    category: "keyboard",
    pageSize: 25,
  });

  assert.equal(request.index, INDEX_NAME);
  assert.equal(request.size, 25);
  assert.deepEqual(request._source, ["product_id", "name", "price", "stock"]);
  assert.deepEqual(request.query.bool.must, [
    {
      multi_match: {
        query: "无线键盘",
        fields: ["name^3", "description"],
      },
    },
  ]);
  assert.deepEqual(request.query.bool.filter, [
    { term: { available: true } },
    { term: { category: "keyboard" } },
  ]);
});

test("buildProductSearch omits an unspecified category", () => {
  const request = buildProductSearch({ keyword: "键盘" });

  assert.deepEqual(request.query.bool.filter, [{ term: { available: true } }]);
});

test("buildProductSearch clamps and truncates pageSize", () => {
  assert.equal(buildProductSearch({ keyword: "键盘", pageSize: 0 }).size, 1);
  assert.equal(
    buildProductSearch({ keyword: "键盘", pageSize: 20.9 }).size,
    20,
  );
  assert.equal(
    buildProductSearch({ keyword: "键盘", pageSize: 1_000 }).size,
    MAX_PAGE_SIZE,
  );
});

test("buildProductSearch rejects invalid business parameters", () => {
  assert.throws(
    () => buildProductSearch({ keyword: " " }),
    /keyword must be a non-empty string/,
  );
  assert.throws(
    () => buildProductSearch({ keyword: "键盘", category: "" }),
    /category must be a non-empty string/,
  );
  assert.throws(
    () => buildProductSearch({ keyword: "键盘", pageSize: Number.NaN }),
    /pageSize must be a finite number/,
  );
});

test("searchProducts sends only the generated request", async () => {
  const calls = [];
  const response = { hits: { hits: [] } };
  const client = {
    async search(request, transportOptions) {
      calls.push({ request, transportOptions });
      return response;
    },
  };

  const result = await searchProducts(client, {
    keyword: "键盘",
    category: "keyboard",
  });

  assert.equal(result, response);
  assert.equal(calls.length, 1);
  assert.deepEqual(
    calls[0].request,
    buildProductSearch({
      keyword: "键盘",
      category: "keyboard",
    }),
  );
  assert.deepEqual(calls[0].transportOptions, { retryOnTimeout: true });
});

test("searchProducts retries 429 responses with exponential backoff", async () => {
  const delays = [];
  let requestCount = 0;
  const response = { hits: { hits: [] } };
  const client = {
    async search() {
      requestCount += 1;
      if (requestCount <= MAX_429_RETRIES) {
        throw Object.assign(new Error("too many requests"), {
          statusCode: 429,
        });
      }
      return response;
    },
  };

  const result = await searchProducts(
    client,
    { keyword: "键盘" },
    {
      sleep: async (milliseconds) => {
        delays.push(milliseconds);
      },
    },
  );

  assert.equal(result, response);
  assert.equal(requestCount, MAX_429_RETRIES + 1);
  assert.deepEqual(delays, [
    INITIAL_RETRY_DELAY_MS,
    INITIAL_RETRY_DELAY_MS * 2,
    INITIAL_RETRY_DELAY_MS * 4,
  ]);
});

test("searchProducts stops after the configured 429 retry limit", async () => {
  const rateLimitError = Object.assign(new Error("too many requests"), {
    statusCode: 429,
  });
  let requestCount = 0;
  const client = {
    async search() {
      requestCount += 1;
      throw rateLimitError;
    },
  };

  await assert.rejects(
    searchProducts(client, { keyword: "键盘" }, { sleep: async () => {} }),
    (error) => error === rateLimitError,
  );
  assert.equal(requestCount, MAX_429_RETRIES + 1);
});

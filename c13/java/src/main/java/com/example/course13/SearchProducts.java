package com.example.course13;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch._types.ElasticsearchException;
import co.elastic.clients.elasticsearch._types.query_dsl.BoolQuery;
import co.elastic.clients.elasticsearch.core.SearchRequest;
import co.elastic.clients.elasticsearch.core.SearchResponse;
import co.elastic.clients.transport.TransportUtils;
import java.io.File;
import java.io.IOException;
import java.util.Objects;
import javax.net.ssl.SSLContext;

public class SearchProducts {

  private static final String INDEX_NAME = "application-client-products-read";
  private static final int DEFAULT_SIZE = 20;
  private static final int MAX_RETRIES = 3;

  public static SearchResponse<Product> searchProducts(String keyword) throws IOException {
    return searchProducts(keyword, null, DEFAULT_SIZE);
  }

  public static SearchResponse<Product> searchProducts(String keyword, int size)
      throws IOException {
    return searchProducts(keyword, null, size);
  }

  public static SearchResponse<Product> searchProducts(String keyword, String category)
      throws IOException {
    return searchProducts(keyword, category, DEFAULT_SIZE);
  }

  public static SearchResponse<Product> searchProducts(String keyword, String category, int size)
      throws IOException {
    SearchRequest request = buildSearchRequest(keyword, category, size);
    try (ElasticsearchClient esClient = getElasticsearchClient()) {
      return executeWithRetries(request, r -> esClient.search(r, Product.class));
    }
  }

  static SearchRequest buildSearchRequest(String keyword, String category, int size) {
    Objects.requireNonNull(keyword);
    if (keyword.isBlank()) {
      throw new IllegalArgumentException("keyword cannot be blank");
    }

    return SearchRequest.of(
        s ->
            s.index(INDEX_NAME)
                .query(
                    q ->
                        q.bool(
                            b -> {
                              BoolQuery.Builder builder =
                                  b.must(
                                      m ->
                                          m.multiMatch(
                                              mm ->
                                                  mm.query(keyword).fields("name", "description")));
                              if (category != null && !category.isBlank()) {
                                builder.filter(
                                    f -> f.term(t -> t.field("category").value(category)));
                              }
                              return builder.filter(
                                  f -> f.term(t -> t.field("available").value(true)));
                            }))
                .size(Math.clamp(size, 1, 100))
                .source(
                    source ->
                        source.filter(
                            filter -> filter.includes("product_id", "name", "price", "stock"))));
  }

  static SearchResponse<Product> executeWithRetries(SearchRequest request, SearchExecutor executor)
      throws IOException {
    for (int retry = 0; ; retry++) {
      try {
        return executor.search(request);
      } catch (ElasticsearchException e) {
        if (e.status() != 429 || retry == MAX_RETRIES) {
          throw e;
        }
      }
    }
  }

  public static ElasticsearchClient getElasticsearchClient() {
    final String esUrl = System.getenv("ES_URL");
    final String esApiKey = System.getenv("ES_API_KEY");
    final String esCa = System.getenv("ES_CA");
    File certFile = new File(esCa);
    SSLContext sslContext;
    try {
      sslContext = TransportUtils.sslContextFromHttpCaCrt(certFile);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
    return ElasticsearchClient.of(b -> b.host(esUrl).apiKey(esApiKey).sslContext(sslContext));
  }

  public static void main(String[] args) throws IOException {
    String keyword = System.getenv("ES_SEARCH_KEYWORD");
    String category = System.getenv("ES_SEARCH_CATEGORY");
    int size = Integer.parseInt(System.getenv("ES_SEARCH_SIZE"));
    System.out.println(searchProducts(keyword, category, size));
  }

  @FunctionalInterface
  interface SearchExecutor {

    SearchResponse<Product> search(SearchRequest request) throws IOException;
  }
}

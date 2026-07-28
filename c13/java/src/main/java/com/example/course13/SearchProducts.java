package com.example.course13;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch._types.ElasticsearchException;
import co.elastic.clients.elasticsearch._types.query_dsl.BoolQuery;
import co.elastic.clients.elasticsearch.core.SearchRequest;
import co.elastic.clients.elasticsearch.core.SearchResponse;
import co.elastic.clients.transport.TransportUtils;
import co.elastic.clients.util.ObjectBuilder;
import java.io.File;
import java.io.IOException;
import java.util.Objects;
import java.util.function.Function;
import javax.net.ssl.SSLContext;

public class SearchProducts {

  public static SearchResponse<Product> searchProducts(String keyword) throws IOException {
    return searchProducts(keyword, null, 20);
  }

  public static SearchResponse<Product> searchProducts(String keyword, int size)
      throws IOException {
    return searchProducts(keyword, null, size);
  }

  public static SearchResponse<Product> searchProducts(String keyword, String category)
      throws IOException {
    return searchProducts(keyword, category, 20);
  }

  public static SearchResponse<Product> searchProducts(String keyword, String category, int size)
      throws IOException {
    Objects.requireNonNull(keyword);
    if (keyword.isBlank()) {
      throw new IllegalArgumentException("keyword cannot be blank");
    }
    ElasticsearchClient esClient = getElasticsearchClient();
    Function<SearchRequest.Builder, ObjectBuilder<SearchRequest>> bu =
        s ->
            s.index("application-client-products-v1")
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
                              builder.filter(f -> f.term(t -> t.field("available").value(true)));
                              return builder;
                            }))
                .size(Math.clamp(size, 1, 100))
                .source(so -> so.filter(f -> f.includes("product_id", "name", "price", "stock")));
    final int maxRetries = 3;
    SearchResponse<Product> response = null;
    for (int retry = 0; retry < maxRetries; retry++) {
      try {
        response = esClient.search(bu, Product.class);
      } catch (ElasticsearchException e) {
        if (e.status() == 429) {
          System.out.println("429 Too Many Requests！Retries: " + retry);
          ++retry;
          continue;
        } else {
          throw e;
        }
      }
      break;
    }
    return response;
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

  public static void main(String[] args) throws IOException {}
}

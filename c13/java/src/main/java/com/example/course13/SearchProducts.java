package com.example.course13;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.SearchResponse;
import co.elastic.clients.transport.TransportUtils;
import java.io.File;
import java.io.IOException;
import javax.net.ssl.SSLContext;

public class SearchProducts {

  public static SearchResponse<Product> searchProducts(
      ElasticsearchClient esClient, String keyword, int page, int pageSize) {
    return null;
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

  public static void main(String[] args) {}
}

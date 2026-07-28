package com.example.course13;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import co.elastic.clients.elasticsearch._types.ElasticsearchException;
import co.elastic.clients.elasticsearch._types.ErrorResponse;
import co.elastic.clients.elasticsearch._types.query_dsl.BoolQuery;
import co.elastic.clients.elasticsearch.core.SearchRequest;
import co.elastic.clients.elasticsearch.core.SearchResponse;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

class SearchProductsTest {

  @Test
  void buildsOnlyAllowedQueryStructure() {
    SearchRequest request = SearchProducts.buildSearchRequest("无线键盘", "keyboard", 20);
    BoolQuery query = request.query().bool();

    assertEquals(List.of("application-client-products-read"), request.index());
    assertEquals(
        List.of("product_id", "name", "price", "stock"), request.source().filter().includes());
    assertEquals(List.of("name", "description"), query.must().getFirst().multiMatch().fields());
    assertEquals("无线键盘", query.must().getFirst().multiMatch().query());
    assertEquals("category", query.filter().get(0).term().field());
    assertEquals("keyboard", query.filter().get(0).term().value().stringValue());
    assertEquals("available", query.filter().get(1).term().field());
    assertTrue(query.filter().get(1).term().value().booleanValue());

    SearchRequest withoutCategory = SearchProducts.buildSearchRequest("键盘", null, 20);
    assertEquals(1, withoutCategory.query().bool().filter().size());
    assertThrows(
        IllegalArgumentException.class, () -> SearchProducts.buildSearchRequest(" ", null, 20));
  }

  @ParameterizedTest
  @CsvSource({"0, 1", "101, 100"})
  void clampsRequestedSize(int requested, int expected) {
    SearchRequest request = SearchProducts.buildSearchRequest("键盘", null, requested);

    assertEquals(expected, request.size().intValue());
  }

  @Test
  void retriesThreeTimesAndAllowsFourthAttempt() throws IOException {
    AtomicInteger attempts = new AtomicInteger();
    ElasticsearchException throttled = tooManyRequests();

    SearchResponse<Product> response =
        SearchProducts.executeWithRetries(
            SearchProducts.buildSearchRequest("键盘", null, 20),
            request -> {
              if (attempts.incrementAndGet() <= 3) {
                throw throttled;
              }
              return null;
            });

    assertNull(response);
    assertEquals(4, attempts.get());
  }

  @Test
  void rethrowsFourthConsecutive429() {
    AtomicInteger attempts = new AtomicInteger();
    ElasticsearchException throttled = tooManyRequests();

    ElasticsearchException thrown =
        assertThrows(
            ElasticsearchException.class,
            () ->
                SearchProducts.executeWithRetries(
                    SearchProducts.buildSearchRequest("键盘", null, 20),
                    request -> {
                      attempts.incrementAndGet();
                      throw throttled;
                    }));

    assertSame(throttled, thrown);
    assertEquals(4, attempts.get());
  }

  private static ElasticsearchException tooManyRequests() {
    ErrorResponse response =
        ErrorResponse.of(
            error ->
                error
                    .status(429)
                    .error(cause -> cause.type("too_many_requests").reason("test throttling")));
    return new ElasticsearchException("es/search", response);
  }
}

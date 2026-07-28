package com.example.course13;

import com.fasterxml.jackson.annotation.JsonProperty;

public class Product {

  @JsonProperty("product_id")
  private String productId;

  private String name;

  private String description;

  private String category;

  private double price;

  private int stock;

  private boolean available;

  public Product() {}

  public Product(
      String productId,
      String name,
      String description,
      String category,
      double price,
      int stock,
      boolean available) {
    this.productId = productId;
    this.name = name;
    this.description = description;
    this.category = category;
    this.price = price;
    this.stock = stock;
    this.available = available;
  }

  public String getProductId() {
    return productId;
  }

  public void setProductId(String productId) {
    this.productId = productId;
  }

  public String getName() {
    return name;
  }

  public void setName(String name) {
    this.name = name;
  }

  public String getDescription() {
    return description;
  }

  public void setDescription(String description) {
    this.description = description;
  }

  public String getCategory() {
    return category;
  }

  public void setCategory(String category) {
    this.category = category;
  }

  public double getPrice() {
    return price;
  }

  public void setPrice(double price) {
    this.price = price;
  }

  public int getStock() {
    return stock;
  }

  public void setStock(int stock) {
    this.stock = stock;
  }

  public boolean isAvailable() {
    return available;
  }

  public void setAvailable(boolean available) {
    this.available = available;
  }
}
